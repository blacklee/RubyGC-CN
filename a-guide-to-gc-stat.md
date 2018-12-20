# Understanding Ruby GC through GC.stat

- Origin Post: https://www.speedshop.co/2017/03/09/a-guide-to-gc-stat.html
- 原文[创作时间 2017-03-09]: https://www.speedshop.co/2017/03/09/a-guide-to-gc-stat.html

> 译注：带有(???)表明我对此句的翻译拿捏不准。水平有限。。

> 译注：「free」这个词拿捏不准就大多保留了原文。我的理解是这样的：「free object」应该是释放了对象（这个是进程内部的操作），如果译掉的话，又可能被理解成释放内存（这是进程和操作系统之家的操作）。

作者：[**Nate Berkopec**](http://twitter.com/nateberkopec)，来自[*speedshop*](https://www.speedshop.co/)

> 概要：你有没有想过Ruby的GC是如何工作的？让我们看看我们能从Ruby为我们提供的`GC.stat`哈希里学到什么。

大多数的Ruby程序员都不清楚垃圾回收在运行时是如何工作的：什么触发了它，它运行得多频繁，它收集了什么以及不收集什么。这不完全是个坏事：动态语言（例如Ruby）中的垃圾回收非常的复杂，而程序员最好只关注编写对用户重要的代码。

但是，偶尔的，你会被GC给懵了：它可能运行得太频繁或者又不够，也可能是你的程序使用了大量的内存但你却不知为何。也可能你只是想知道GC是如何工作的。

我们学习CRuby（用C写的标准Ruby运行时）关于垃圾回收的一个方法是看看它内建的`GC`模块。如果你还没读过[这个模块的文档](https://ruby-doc.org/core-2.4.0/GC.html)，那得读一下，它有几个有意思的方法。但现在，我们只看这一个方法：`GC.stat`。

`GC.stat`输出一组不同数字的哈希，但它们并没有被良好的文档描述，并且其中一些非常容易让人混淆，除非你阅读了相关的C代码！不过我帮你读了，现在一起看看`GC.stat`提供的信息吧。

这是我在一个用 Ruby-2.4.0 刚刚启动的`irb`会话中执行`GC.stat`的输出：

```ruby
{
  :count=>15,
  :heap_allocated_pages=>63,
  :heap_sorted_length=>63,
  :heap_allocatable_pages=>0,
  :heap_available_slots=>25679,
  :heap_live_slots=>25506,
  :heap_free_slots=>173,
  :heap_final_slots=>0,
  :heap_marked_slots=>17773,
  :heap_eden_pages=>63,
  :heap_tomb_pages=>0,
  :total_allocated_pages=>63,
  :total_freed_pages=>0,
  :total_allocated_objects=>133299,
  :total_freed_objects=>107793,
  :malloc_increase_bytes=>45712,
  :malloc_increase_bytes_limit=>16777216,
  :minor_gc_count=>13,
  :major_gc_count=>2,
  :remembered_wb_unprotected_objects=>182,
  :remembered_wb_unprotected_objects_limit=>352,
  :old_objects=>17221,
  :old_objects_limit=>29670,
  :oldmalloc_increase_bytes=>46160,
  :oldmalloc_increase_bytes_limit=>16777216
}
```

> 注：Ruby-2.5.1的输出是一样的

OK，很多东西，这有25个*没有文档*的键值。

首先，我们看看 `GC counts`：

```ruby
{
  :count=>15,
  # ...
  :minor_gc_count=>13,
  :major_gc_count=>2
}
```

这几个非常直接。`minor_gc_count`和`major_gc_count`是Ruby进程启动之后的各类型GC运行次数。万一你不知道，自从Ruby-2.1开始就有个*2*种垃圾回收，major和minor。minor GC只尝试回收「新」的对象——存活时间小于等于3次GC周期。而major GC会尝试回收*所有*对象，甚至是存活时间超过3次GC周期。`count` = `minor_gc_count` + `major_gc_count`。如果想了解更多，可以参考我在FOSDEM上关于[the history of Ruby Garbage Collection](https://www.youtube.com/watch?v=lcQ-hIfiljA)的讲解。

出于几个原因跟踪GC次数会是有用的。例如，某个特定的后台任务总是触发GC（以及触发了多少次）。例如，这是一个Rack中间件可以记录当服务器处理一个请求时的GC次数变化：

```ruby
class GCCounter
  def initialize(app)
    @app = app
  end

  def call(env)
    gc_counts_before = GC.stat.select { |k,v| k =~ /count/ }
    @app.call(env)
    gc_counts_after = GC.stat.select { |k,v| k =~ /count/ }
    puts gc_counts_before.merge(gc_counts_after) { |k, vb, va| va - vb }
  end
end
```

如果你的服务是多线程的，那么这个数据不会100%的准确，因为其他的线程弄出来的内存压力也可能触发GC，但这是一个入口。

现在，我们继续看`堆数量`（`heap numbers`）的统计：

```ruby
{
  # Page numbers
  :heap_allocated_pages=>63,
  :heap_sorted_length=>63,
  :heap_allocatable_pages=>0,

  # Slots
  :heap_available_slots=>25679,
  :heap_live_slots=>25506,
  :heap_free_slots=>173,
  :heap_final_slots=>0,
  :heap_marked_slots=>17773,

  # Eden and Tomb
  :heap_eden_pages=>63,
  :heap_tomb_pages=>0
}
```

在这里，`堆heap`是一个C数据结构，有时也称为`对象空间ObjectSpace`，在其中我们保持了对当前所有活Ruby对象的引用，每一个 堆heap *页面page* 包含了大约408个*槽slots*，每个 槽slot 包含了一个活的Ruby对象的信息。

- 首先，你得到了整个Ruby对象空间的总大小信息。`heap_allocated_pages`是当前已分配的堆空间的数字，这些页面pages可能完全是空的、完全满的、或者是中间状态。
- `heap_sorted_length`是内存中堆的实际大小 —— 如果我们有 10 个堆页面，然后 free 了中间某个页面，那么 堆页面 的 `长度length` 仍然是 10（因为我们没法在内存中移动页面）。`heap_sorted_length`总是大于等于实际分配的页面数。
- 最后，`heap_allocatable_pages` —— 这是Ruby当前拥有的 堆页面大小 的一些（已经`分配的 malloced`）内存块，我们可以分配一个新的堆页面。如果Ruby需要为增加的对象分配新的堆页面，那就会首先使用这个空间。

OK，现在我们拿到了一堆和单个对象的*槽slots*有关的数字。`heap_available_slots`，很明显是堆页面中所有槽的数量 —— `GC.stat[:heap_allocated_pages]` 恒等于 `GC.stat[:heap_available_slots]` / `GC::INTERNAL_CONSTANTS[:HEAP_PAGE_OBJ_LIMIT]`。然后：
- `heap_live_slots`是活跃对象数；
- `heap_free_slots`是堆页面中空的槽；
- `heap_final_slots`是被*析构函数finalizers*附着了的对象槽。析构函数是Ruby中一类朦胧的特性 —— 它们是对象将被释放时运行的Procs。例如：`ObjectSpace.define_finalizer(self, self.class.method(:finalize).to_proc)`
- `heap_marked_slots`几乎是*旧对象*（存活超过3次GC周期的对象）的数量加上*写屏障无保护对象 write barrier unprotected objects*（一会细说）的数量。

> 注：上面两段列表，在原文中是段落形式，但是弄出列表形式似乎好点。

至于 `GC.stat` 中槽数量的实际使用，如果你遇到内存膨胀问题的话我建议监控`heap_free_slots`。大量的空对象槽（free slots???）通常预示着你有几个actions分配了大量的对象然后又释放了它们，这会不停地增加你的Ruby进程的内存。若想了解修复这问题的更多技巧，[参考我在Rubyconf上关于Ruby内存问题的演讲](http://confreaks.tv/videos/rubyconf2016-halve-your-memory-usage-with-these-12-weird-tricks)。

现在，我们有`tomb_pages`和`eden_pages`，`eden_pages`是包含*至少一个*活对象的堆页面。`tomb_pages`*不包含活对象*，所以有完全空的对象槽(free slots???)。Ruby运行时*只释放tomb_pages返回操作系统*，而`eden_pages`则永远不被free。

简单的，还有几个**累积的 已分配/已free 数字**

```ruby
{
  :total_allocated_pages=>63,
  :total_freed_pages=>0,
  :total_allocated_objects=>133299,
  :total_freed_objects=>107793
}
```

这些数字是进程整个生命周期的*累积*值 —— 它们不会被重置、减小。根据它们的变量名称就已经很好理解了。

最后，我们还有 **垃圾回收阈值 garbage collection thresholds**：

```ruby
{
  :malloc_increase_bytes=>45712,
  :malloc_increase_bytes_limit=>16777216,
  :remembered_wb_unprotected_objects=>182,
  :remembered_wb_unprotected_objects_limit=>352,
  :old_objects=>17221,
  :old_objects_limit=>29670,
  :oldmalloc_increase_bytes=>46160,
  :oldmalloc_increase_bytes_limit=>16777216
}
```

呃，Ruby开发者的一个主要误解是GC*何时*被触发。我们可以通过`GC.start`手动触发GC，但这不发生于产品线。一些人觉得GC是根据某种定时器（例如每隔几秒或几个请求）来运行的，事实并非如此。

- minor GC是当缺少空槽时被触发的。Ruby不会自动GC任何对象 —— 它只当空间不足时运行回收。所以当没有`free_slots`剩下时，Ruby运行minor GC —— 标记并且清除所有新对象和*记忆集*中*未被写屏障保护*的对象。这些术语随后有解释。
- major GC将在minor GC运行后仍然缺少空槽时被触发，或者是以下4个阈值中任何一个被突破了：
  1. oldmalloc
  2. malloc
  3. old object count
  4. 「shady」/「写屏障未保护数」

`GC.stat` 包含了这四个阈值（限制）和运行时的当前状态。
- `malloc_increase_bytes` 指的是Ruby为「堆（我们已经讨论过的）」*外* 对象分配的空间。堆页面里的每一个对象槽只有40字节（参考`GC::INTERNAL_CONSTANTS[:RVALUE_SIZE]`），那当对象大小超过40字节（比如长字符串）时会发生什么呢？我们为这个对象在其他任何地方`malloc`空间！如果我们为一个字符串分配了80字节的空间，那 `malloc_increase_bytes` 就将增加80。当这个数值抵达了限制，就触发了一次major GC。
- `oldmalloc_increase_bytes` 和 `malloc_increase_bytes` 类似，但只针对 *old* 对象。
- `remembered_wb_unprotected_objects` 是*已记忆集remembered set*中的部分但没有被*写屏障write-barrier*保护 的对象数量。
  1. 写屏障是一个简单的Ruby运行时和对象之间的接口，能让我们在对象被创建时追踪它的引用和被引用。C扩展可以不经过写屏障而创建到对象的引用，所以被C扩展引用了的对象被称为「shady」或者「写屏障未保护的」。
  2. 已记忆集是拥有引用*新new*对象的*老old*对象的列表集合。
- `old_objects` 被标记为 老 对象槽的数量。

如果你的问题是major GC的次数过多，那追踪这些阈值可能对debug有帮助。

我希望这是对 GC.stat 的教育看法 —— 它是个信息丰富的哈希，能用来在需要修复不良GC行为时构建临时的debug方案。

----

不是非常有把握的翻译：

- 1.
  - `malloc_increase_bytes` refers to when Ruby allocates space for objects *outside *of the “heap” we’ve been discussing so far
  - `malloc_increase_bytes` 指的是Ruby为「堆（我们已经讨论过的）」*外* 对象分配的空间
- 2.
  - `remembered_wb_unprotected_objects` is a count of objects which are not protected by the `write-barrier` and are part of the remembered set
  - `remembered_wb_unprotected_objects` 是*已记忆集remembered set*中的部分但没有被*写屏障write-barrier*保护 的对象数量。
- 3.
  - The write-barrier is simply a interface between the Ruby runtime and an object, so that we can track references to and from the object when they’re created
  - 写屏障是一个简单的Ruby运行时和对象之间的接口，能让我们在对象被创建时追踪它的引用和被引用。
- 4.
  - The part of GC.stat we’re looking at here shows each of those four thresholds (the limit) and the current state of the runtime on the way to that threshold.
  - `GC.stat` 包含了这四个阈值（限制）和运行时的当前状态
