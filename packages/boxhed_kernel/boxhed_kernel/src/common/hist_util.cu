/*!
 * Copyright 2018~2020 XGBoost contributors
 */

#include <boxhed_kernel/logging.h>

#include <thrust/copy.h>
#include <thrust/functional.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/iterator/transform_iterator.h>
#include <thrust/iterator/discard_iterator.h>
#include <thrust/reduce.h>
#include <thrust/sort.h>
#include <thrust/binary_search.h>
#include <thrust/execution_policy.h>

#include <memory>
#include <mutex>
#include <utility>
#include <vector>

#include "device_helpers.cuh"
#include "hist_util.h"
#include "hist_util.cuh"
#include "math.h"  // NOLINT
#include "quantile.h"
#include "categorical.h"
#include "boxhed_kernel/host_device_vector.h"


namespace boxhed_kernel {
namespace common {

constexpr float SketchContainer::kFactor;

namespace detail {
size_t RequiredSampleCutsPerColumn(int max_bins, size_t num_rows) {
  double eps = 1.0 / (WQSketch::kFactor * max_bins);
  size_t dummy_nlevel;
  size_t num_cuts;
  WQuantileSketch<bst_float, bst_float>::LimitSizeLevel(
      num_rows, eps, &dummy_nlevel, &num_cuts);
  return std::min(num_cuts, num_rows);
}

size_t RequiredSampleCuts(bst_row_t num_rows, bst_feature_t num_columns,
                          size_t max_bins, size_t nnz) {
  auto per_column = RequiredSampleCutsPerColumn(max_bins, num_rows);
  auto if_dense = num_columns * per_column;
  auto result = std::min(nnz, if_dense);
  return result;
}

size_t RequiredMemory(bst_row_t num_rows, bst_feature_t num_columns, size_t nnz,
                      size_t num_bins, bool with_weights) {
  size_t peak = 0;
  // 0. Allocate cut pointer in quantile container by increasing: n_columns + 1
  size_t total = (num_columns + 1) * sizeof(SketchContainer::OffsetT);
  // 1. Copy and sort: 2 * bytes_per_element * shape
  total += BytesPerElement(with_weights) * num_rows * num_columns;
  peak = std::max(peak, total);
  // 2. Deallocate bytes_per_element * shape due to reusing memory in sort.
  total -= BytesPerElement(with_weights) * num_rows * num_columns / 2;
  // 3. Allocate colomn size scan by increasing: n_columns + 1
  total += (num_columns + 1) * sizeof(SketchContainer::OffsetT);
  // 4. Allocate cut pointer by increasing: n_columns + 1
  total += (num_columns + 1) * sizeof(SketchContainer::OffsetT);
  // 5. Allocate cuts: assuming rows is greater than bins: n_columns * limit_size
  total += RequiredSampleCuts(num_rows, num_bins, num_bins, nnz) * sizeof(SketchEntry);
  // 6. Deallocate copied entries by reducing: bytes_per_element * shape.
  peak = std::max(peak, total);
  total -= (BytesPerElement(with_weights) * num_rows * num_columns) / 2;
  // 7. Deallocate column size scan.
  peak = std::max(peak, total);
  total -= (num_columns + 1) * sizeof(SketchContainer::OffsetT);
  // 8. Deallocate cut size scan.
  total -= (num_columns + 1) * sizeof(SketchContainer::OffsetT);
  // 9. Allocate final cut values, min values, cut ptrs: std::min(rows, bins + 1) *
  //    n_columns + n_columns + n_columns + 1
  total += std::min(num_rows, num_bins) * num_columns * sizeof(float);
  total += num_columns *
           sizeof(std::remove_reference_t<decltype(
                      std::declval<HistogramCuts>().MinValues())>::value_type);
  total += (num_columns + 1) *
           sizeof(std::remove_reference_t<decltype(
                      std::declval<HistogramCuts>().Ptrs())>::value_type);
  peak = std::max(peak, total);

  return peak;
}

size_t SketchBatchNumElements(size_t sketch_batch_num_elements,
                              bst_row_t num_rows, bst_feature_t columns,
                              size_t nnz, int device,
                              size_t num_cuts, bool has_weight) {
  if (sketch_batch_num_elements == 0) {
    auto required_memory = RequiredMemory(num_rows, columns, nnz, num_cuts, has_weight);
    // use up to 80% of available space
    auto avail = dh::AvailableMemory(device) * 0.8;
    if (required_memory > avail) {
      sketch_batch_num_elements = avail / BytesPerElement(has_weight);
    } else {
      sketch_batch_num_elements = std::min(num_rows * static_cast<size_t>(columns), nnz);
    }
  }
  return sketch_batch_num_elements;
}

void SortByWeight(dh::device_vector<float>* weights,
                  dh::device_vector<Entry>* sorted_entries) {
  // Sort both entries and wegihts.
  dh::XGBDeviceAllocator<char> alloc;
  thrust::sort_by_key(thrust::cuda::par(alloc), sorted_entries->begin(),
                      sorted_entries->end(), weights->begin(),
                      detail::EntryCompareOp());

  // Scan weights
  dh::XGBCachingDeviceAllocator<char> caching;
  thrust::inclusive_scan_by_key(thrust::cuda::par(caching),
                                sorted_entries->begin(), sorted_entries->end(),
                                weights->begin(), weights->begin(),
                                [=] __device__(const Entry& a, const Entry& b) {
                                  return a.index == b.index;
                                });
}

struct IsCatOp {
  XGBOOST_DEVICE bool operator()(FeatureType ft) { return ft == FeatureType::kCategorical; }
};

void RemoveDuplicatedCategories(
    int32_t device, MetaInfo const &info, Span<bst_row_t> d_cuts_ptr,
    dh::device_vector<Entry> *p_sorted_entries,
    dh::caching_device_vector<size_t>* p_column_sizes_scan) {
  auto d_feature_types = info.feature_types.ConstDeviceSpan();
  auto& column_sizes_scan = *p_column_sizes_scan;
  if (!info.feature_types.Empty() &&
      thrust::any_of(dh::tbegin(d_feature_types), dh::tend(d_feature_types),
                     IsCatOp{})) {
    auto& sorted_entries = *p_sorted_entries;
    // Removing duplicated entries in categorical features.
    dh::caching_device_vector<size_t> new_column_scan(column_sizes_scan.size());
    dh::SegmentedUnique(
        column_sizes_scan.data().get(),
        column_sizes_scan.data().get() + column_sizes_scan.size(),
        sorted_entries.begin(), sorted_entries.end(),
        new_column_scan.data().get(), sorted_entries.begin(),
        [=] __device__(Entry const &l, Entry const &r) {
          if (l.index == r.index) {
            if (IsCat(d_feature_types, l.index)) {
              return l.fvalue == r.fvalue;
            }
          }
          return false;
        });

    // Renew the column scan and cut scan based on categorical data.
    auto d_old_column_sizes_scan = dh::ToSpan(column_sizes_scan);
    dh::caching_device_vector<SketchContainer::OffsetT> new_cuts_size(
        info.num_col_ + 1);
    auto d_new_cuts_size = dh::ToSpan(new_cuts_size);
    auto d_new_columns_ptr = dh::ToSpan(new_column_scan);
    CHECK_EQ(new_column_scan.size(), new_cuts_size.size());
    dh::LaunchN(device, new_column_scan.size(), [=] __device__(size_t idx) {
      d_old_column_sizes_scan[idx] = d_new_columns_ptr[idx];
      if (idx == d_new_columns_ptr.size() - 1) {
        return;
      }
      if (IsCat(d_feature_types, idx)) {
        // Cut size is the same as number of categories in input.
        d_new_cuts_size[idx] =
            d_new_columns_ptr[idx + 1] - d_new_columns_ptr[idx];
      } else {
        d_new_cuts_size[idx] = d_cuts_ptr[idx] - d_cuts_ptr[idx];
      }
    });
    // Turn size into ptr.
    thrust::exclusive_scan(thrust::device, new_cuts_size.cbegin(),
                           new_cuts_size.cend(), d_cuts_ptr.data());
  }
}
}  // namespace detail

inline void ExtractUniqueEntries(
                                int device,
                                int num_columns,
                                int num_cuts_per_feature,
                                data::IsValidFunctor is_valid,
                                dh::device_vector<Entry> *sorted_entries,
                                dh::device_vector<Entry> *unique_entries,
                                dh::caching_device_vector<size_t>* unique_column_sizes_scan,
                                HostDeviceVector<SketchContainer::OffsetT>* unique_cuts_ptr) {

  dh::XGBDeviceAllocator<char> alloc;
  thrust::copy(thrust::cuda::par(alloc), sorted_entries->begin(), 
               sorted_entries->end(), unique_entries->begin());

  auto new_end = thrust::unique(thrust::cuda::par(alloc),
                 unique_entries->begin(), 
                 unique_entries->end(),
                 [=] __device__(const Entry& a, const Entry& b) {
                    if (a.index == b.index) {
                        return a.fvalue == b.fvalue;
                    }
                    return false;
                    }
               );

  unique_entries->resize(thrust::distance(unique_entries->begin(), new_end));

  auto batch_unique_it = dh::MakeTransformIterator<data::COOTuple>(
      unique_entries->data().get(),
      [] __device__(Entry const &e) -> data::COOTuple {
        return {0, e.index, e.fvalue};  // row_idx is not needed for scanning column size.
      });

  unique_column_sizes_scan->resize(num_columns + 1, 0);
  auto d_unique_column_sizes_scan = unique_column_sizes_scan->data().get();
  dh::LaunchN(device, unique_entries->size(), [=] __device__(size_t idx) {
    auto e = batch_unique_it[idx];
    if (is_valid(e)) {
      atomicAdd(&d_unique_column_sizes_scan[e.column_idx], static_cast<size_t>(1));
    }
  });

  unique_cuts_ptr->SetDevice(device);
  unique_cuts_ptr->Resize(num_columns + 1, 0);

  auto unique_cut_ptr_it = dh::MakeTransformIterator<size_t>(
      unique_column_sizes_scan->begin(), [=] __device__(size_t column_size) {
        return thrust::min(static_cast<size_t>(num_cuts_per_feature), column_size);
      });


  thrust::exclusive_scan(thrust::cuda::par(alloc), unique_cut_ptr_it,
                         unique_cut_ptr_it + unique_column_sizes_scan->size(),
                         unique_cuts_ptr->DevicePointer());
}


void ProcessBatch(int device, MetaInfo const &info, const SparsePage &page,
                  size_t begin, size_t end, SketchContainer *sketch_container,
                  int num_cuts_per_feature, size_t num_columns) {
  dh::XGBCachingDeviceAllocator<char> alloc;
  const auto& host_data = page.data.ConstHostVector();
  dh::device_vector<Entry> sorted_entries(host_data.begin() + begin,
                                          host_data.begin() + end);
  thrust::sort(thrust::cuda::par(alloc), sorted_entries.begin(),
               sorted_entries.end(), detail::EntryCompareOp());

  HostDeviceVector<SketchContainer::OffsetT> cuts_ptr;
  dh::caching_device_vector<size_t> column_sizes_scan;
  data::IsValidFunctor dummy_is_valid(std::numeric_limits<float>::quiet_NaN());
  auto batch_it = dh::MakeTransformIterator<data::COOTuple>(
      sorted_entries.data().get(),
      [] __device__(Entry const &e) -> data::COOTuple {
        return {0, e.index, e.fvalue};  // row_idx is not needed for scanning column size.
      });

  dh::device_vector<Entry> unique_entries(sorted_entries.size());
  dh::caching_device_vector<size_t> unique_column_sizes_scan;
  HostDeviceVector<SketchContainer::OffsetT> unique_cuts_ptr;
  ExtractUniqueEntries(device,
                       num_columns,
                       num_cuts_per_feature,
                       dummy_is_valid,
                       &sorted_entries,
                       &unique_entries,
                       &unique_column_sizes_scan,
                       &unique_cuts_ptr);

  num_cuts_per_feature = std::min(num_cuts_per_feature, static_cast<int>(256));
 
  detail::GetColumnSizesScan(device, num_columns, num_cuts_per_feature,
                             batch_it, dummy_is_valid,
                             0, sorted_entries.size(),
                             &cuts_ptr, &column_sizes_scan);
  auto d_cuts_ptr = cuts_ptr.DeviceSpan();
  detail::RemoveDuplicatedCategories(device, info, d_cuts_ptr, &sorted_entries,
                                     &column_sizes_scan);

  CHECK_EQ(d_cuts_ptr.size(), column_sizes_scan.size());

  auto d_unique_cuts_ptr        = unique_cuts_ptr.DeviceSpan();
  auto const& h_unique_cuts_ptr = unique_cuts_ptr.ConstHostVector();

  sketch_container->Push(dh::ToSpan(sorted_entries), dh::ToSpan(column_sizes_scan),
                         dh::ToSpan(unique_entries),
                         d_unique_cuts_ptr, h_unique_cuts_ptr.back());
  sorted_entries.clear();
  unique_entries.clear();
  sorted_entries.shrink_to_fit();
  unique_entries.shrink_to_fit();
  CHECK_EQ(sorted_entries.capacity(), 0);
  CHECK_EQ(unique_entries.capacity(), 0);
  CHECK_NE(cuts_ptr.Size(), 0);
  CHECK_NE(unique_cuts_ptr.Size(), 0);
}

HistogramCuts DeviceSketch(int device, DMatrix* dmat, int max_bins,
                           size_t sketch_batch_num_elements) {
  dmat->Info().feature_types.SetDevice(device);
  dmat->Info().feature_types.ConstDevicePointer();  // pull to device early
  // Configure batch size based on available memory
  bool has_weights = dmat->Info().weights_.Size() > 0;
  size_t num_cuts_per_feature =
      detail::RequiredSampleCutsPerColumn(max_bins, dmat->Info().num_row_);
  sketch_batch_num_elements = detail::SketchBatchNumElements(
      sketch_batch_num_elements,
      dmat->Info().num_row_,
      dmat->Info().num_col_,
      dmat->Info().num_nonzero_,
      device, num_cuts_per_feature, has_weights);

  HistogramCuts cuts;
  SketchContainer sketch_container(dmat->Info().feature_types, max_bins, dmat->Info().num_col_,
                                   dmat->Info().num_row_, device);

  dmat->Info().weights_.SetDevice(device);
  for (const auto& batch : dmat->GetBatches<SparsePage>()) {
    size_t batch_nnz = batch.data.Size();
    auto const& info = dmat->Info();
    for (auto begin = 0ull; begin < batch_nnz; begin += sketch_batch_num_elements) {
      size_t end = std::min(batch_nnz, size_t(begin + sketch_batch_num_elements));
      ProcessBatch(device, dmat->Info(), batch, begin, end, &sketch_container,
                   num_cuts_per_feature, dmat->Info().num_col_);
      break;
    }
  }
  sketch_container.MakeCuts(&cuts);
  return cuts;
}
}  // namespace common
}  // namespace boxhed_kernel
