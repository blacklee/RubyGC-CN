module GC
  def self.grouped_stat
    stat = GC.stat
    arr = [{gc_count: {ma: stat[:major_gc_count], mi: stat[:minor_gc_count], t: stat[:count]}}]
    arr << {thresholds: {
      malloc_increase_bytes: [stat[:malloc_increase_bytes], stat[:malloc_increase_bytes_limit]],
      remembered_wb_unprotected_objects: [stat[:remembered_wb_unprotected_objects], stat[:remembered_wb_unprotected_objects_limit]],
      old_objects: [stat[:old_objects], stat[:old_objects_limit]],
      oldmalloc_increase_bytes: [stat[:oldmalloc_increase_bytes], stat[:oldmalloc_increase_bytes_limit]]
    }}
    arr << {heap_pages: {allocated: stat[:heap_allocated_pages], sorted_length: stat[:heap_sorted_length], allocatable: stat[:heap_allocatable_pages], eden: stat[:heap_eden_pages], tomb: stat[:heap_tomb_pages]}}
    arr << {heap_slots: {available: stat[:heap_available_slots], live: stat[:heap_live_slots], free: stat[:heap_free_slots], final: stat[:heap_final_slots], marked: stat[:heap_marked_slots]}}
    arr << {total: {
      allocated_pages: stat[:total_allocated_pages], freed_pages: stat[:total_freed_pages],
      allocated_objects: stat[:total_allocated_objects], freed_objects: stat[:total_freed_objects]
    }}
    arr
  end
end

# usages
#   GC.grouped_stat.each {|item| logger.info(item.inspect)}
# output:
#   {:gc_count=>{:ma=>10, :mi=>42, :t=>52}}
#   {:thresholds=>{:malloc_increase_bytes=>[150144, 24554870], :remembered_wb_unprotected_objects=>[3514, 3606], :old_objects=>[263969, 435948], :oldmalloc_increase_bytes=>[150592, 16777216]}}
#   {:heap_pages=>{:allocated=>929, :sorted_length=>929, :allocatable=>0, :eden=>929, :tomb=>0}}
#   {:heap_slots=>{:available=>378645, :live=>378033, :free=>612, :final=>0, :marked=>280502}}
#   {:total=>{:allocated_pages=>929, :freed_pages=>0, :allocated_objects=>1527009, :freed_objects=>1148976}}
