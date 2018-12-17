# Debugging memory leaks in Ruby

- Origin Post: https://samsaffron.com/archive/2015/03/31/debugging-memory-leaks-in-ruby
- 原文[创作时间 2015-3-31]: https://samsaffron.com/archive/2015/03/31/debugging-memory-leaks-in-ruby

> 译者注：带有(???)表明我对此句的翻译拿捏不准，也在文尾统一列出。水平有限。。

本文是关于诊断并修复Ruby内存泄漏的一些工具、提示和技术。

----

在每一个Rails开发者的生活中的某个时刻他一定会遇到内存泄漏的问题。内存也许是稳定的小幅增长，也许是任务队列中某些任务执行时的井喷增长。

可悲的是，大多数Ruby开发者仅仅是简单的采用了[monit](http://mmonit.com/monit/), [inspeqtor](https://github.com/mperham/inspeqtor)或者[unicorn worker killers](https://github.com/kzk/unicorn-worker-killer)，这可以让人暂时忽略这个问题，从而去做些更**重要**的事。

不幸的是，这种处理方法导致了一些不好的副作用。除了效率不高，不稳定、需要更多内存让社区对Ruby缺乏信心。监控、重启进程是你武器库中很重要的工具，但它充其量只是权宜之计和保障，它不是个解决方案。

我们有一些极好的工具可以用来处理内存泄漏，**特别**是简单的内存泄漏：**managed memory leak**。

## Are we leaking? 真的有泄漏？

第一也是**最重要**的处理内存问题的步骤是用图表来监控内存使用情况。在[Discourse](http://www.discourse.org/)里我们使用了[Graphite](http://graphite.wikidot.com/), [statsd](https://github.com/etsy/statsd/)和[Grafana](http://grafana.org/)这一系列的组合工具来图表化应用程序的各项指标。

前一阵子我为此工作打包了一个 [Docker镜像文件](https://github.com/SamSaffron/graphite_docker)，它和我们目前正在运用的工具非常类似。如果不想自己造轮子，你可以看看[New Relic](http://newrelic.com/), [Datadog](https://www.datadoghq.com/)或者其他基于云服务的度量提供者。你首先需要追踪的关键指标是Ruby进程的RSS（[Resident set size](https://en.wikipedia.org/wiki/Resident_set_size): 实际使用物理内存(包含共享库占用的内存)）。在Discourse中我们观察Web服务器[Unicorn](http://unicorn.bogomips.org/)和任务队列[Sidekiq](http://sidekiq.org/)的最大RSS数值。

Discourse被用多个Docker容器部署在多台机器上。我们使用了定制的[Docker容器](https://github.com/discourse/discourse_docker/tree/03b50438d73dbe6076a5a4179e336afaef2b28c2/image/monitor)来监控所有其他Docker容器。这个定制的容器启动后能访问Docker套接字(???)，所以它能够询问Docker关于Docker的信息。它使用了`docker exec`来得到容器内运行的所有进程的所有类别的信息。

> 注：Discourse使用了unicorn主进程来启动多个子workers和任务队列，这不可能由单进程单容器的方式达成（在分支间共享内存）(???)。

利用此信息，我们就能轻松的为任何机器任何容器绘制内存占用(RSS)趋势图了：

![](https://discuss.samsaffron.com/uploads/default/_optimized/dc2/faf/6a0f49a725_690x273.png)

长期图表对任何内存泄漏分析都很**决定性的**，它让我们能够看到问题何时发生，内存的增长率和增长图形。**进程不稳定吗？它和某个任务执行有关系吗？**

当处理与C扩展有关的内存泄漏时，有此信息是决定性的。孤立的C扩展内存泄漏通常牵涉到[valgrind](http://valgrind.org/)和自行编译的支持用valgrind进行debug的Ruby版本。这是个极其困难的工作，不到最后我们都不愿意涉及它。在[升级EventMachine](https://github.com/eventmachine/eventmachine/pull/586)后，隔离趋势开始变得更加简单(???)。

## Managed memory leaks

不同于unmanaged的泄漏，处理managed的泄漏很直接。Ruby2.1+的新工具让调试这些泄漏很简单。

Ruby2.1+里我们能做的最棒的事是爬取进程的对象空间(object space)，做一个快照，等待一会，再做一个快照，然后进行对比。对此我有一个简单的实现，它在Discourse里的[MemoryDiagnositics](https://github.com/discourse/discourse/blob/586cca352d1bb2bb044442d79a6520c9b37ed1ae/lib/memory_diagnostics.rb)，不过让它正确工作却需要些小诡计。当做快照的时候你需要fork你的进程，如此以不干涉正在运行的进程，你能收集的信息非常简单。我们能断定某些对象泄漏了，但我们无法确定它们是在哪里被分配的。

```txt
3377 objects have leaked
Summary:
String: 1703
Bignum: 1674

Sample Items:
Bignum: 40 bytes
Bignum: 40 bytes
String: 
Bignum: 40 bytes
String: 
Bignum: 40 bytes
String: 
```

如果我们够幸运，可以得到一些泄漏了的number和string，这些的揭露足以帮助我们弄清它们。

另外我们还有`GC.stat`可以告诉我们现在有多少存活的对象及其他信息。

这个信息十分有限，我们能断定发生了内存泄漏，但查找原因则十分困难。

> 注：一个很有意思的度量标准是`GC.stat[:heap_live_slots]`，通过这个信息，我们能简单的判断现在有一个managed对象泄漏。

## Managed heap dumping

Ruby2.1引入了[heap dumping](http://tmm1.net/ruby21-objspace/)，如果你启用了分配跟踪(allocation tracing)你将得到一些非常有意思的信息。

收集堆导出的方法非常简单

**开启分配跟踪** **Turn on allocation tracing**：

```ruby
require 'objspace'
ObjectSpace.trace_object_allocations_start
```

这会**显著的**让你的程序变慢并且导致占用更多的内存。不过，这是收集有用信息的钥匙，而且之后可以关闭。我在分析时会在启动程序之后马上运行它。

我最后一次调试Discourse的Sidekiq内存问题时我在一台空闲机器上部署了额外的Docker镜像，这给了我完全的自由，不必去担心影响到SLA（服务级别协议service-level agreement）。

**下一步，等待** **Next, play the waiting game**

当内存清楚的泄漏后，（你可以观察`GC.stat`或者通过测定RSS情况），运行：

```ruby
io=File.open("/tmp/my_dump", "w")
ObjectSpace.dump_all(output: io); 
io.close
```

## Running Ruby in an already running process

要让此方法工作，我们需要在一个已启动的进程内部运行Ruby代码。

幸运的是，[rbtrace](https://github.com/tmm1/rbtrace) gem允许我们这样做（还有更多），此外在生产环境中运行它也是**`安全`**的。

我们可以这样强制Sidekiq导出它的堆信息：

```shell
bundle exec rbtrace -p $SIDEKIQ_PID -e 'Thread.new{GC.start;require "objspace";io=File.open("/tmp/ruby-heap.dump", "w"); ObjectSpace.dump_all(output: io); io.close}'
```

rbtrace运行在一个限制性的上下文中，一个巧妙的技巧是用`Thread.new`来突破陷阱环境(???)。

我们也可以用rbtrace在进程外部收集信息，例如：

```shell
bundle exec rbtrace -p 6744 -e 'GC.stat'
/usr/local/bin/ruby: warning: RUBY_HEAP_MIN_SLOTS is obsolete. Use RUBY_GC_HEAP_INIT_SLOTS instead.
*** attached to process 6744
>> GC.stat
=> {:count=>49, :heap_allocated_pages=>1960, :heap_sorted_length=>1960, :heap_allocatable_pages=>12, :heap_available_slots=>798894, :heap_live_slots=>591531, :heap_free_slots=>207363, :heap_final_slots=>0, :heap_marked_slots=>335775, :heap_swept_slots=>463124, :heap_eden_pages=>1948, :heap_tomb_pages=>12, :total_allocated_pages=>1960, :total_freed_pages=>0, :total_allocated_objects=>13783631, :total_freed_objects=>13192100, :malloc_increase_bytes=>32568600, :malloc_increase_bytes_limit=>33554432, :minor_gc_count=>41, :major_gc_count=>8, :remembered_wb_unprotected_objects=>12175, :remembered_wb_unprotected_objects_limit=>23418, :old_objects=>309750, :old_objects_limit=>618416, :oldmalloc_increase_bytes=>32783288, :oldmalloc_increase_bytes_limit=>44484250}
*** detached from process 6744
```

### Analyzing the heap dump

当拿到这个丰富的堆信息后我们开始分析，首先要看的报告是每一个GC世代对象数量。

当开启了对象分配追踪后，运行时会为所有对象分配附加丰富的信息，包括：

1. 分配给它的GC世代(???)。
2. 分配该对象的代码位置（文件名+代码行）
3. 一个被修剪了的值
4. bytesize
5. …………其他

导出的文件是JSON格式的，每行都可以简单的被解析，例如

```json
{"address":"0x7ffc567fbf98", "type":"STRING", "class":"0x7ffc565c4ea0", "frozen":true, "embedded":true, "fstring":true, "bytesize":18, "value":"ensure in dispatch", "file":"/var/www/discourse/vendor/bundle/ruby/2.2.0/gems/activesupport-4.1.9/lib/active_support/dependencies.rb", "line":247, "method":"require", "generation":7, "memsize":40, "flags":{"wb_protected":true, "old":true, "long_lived":true, "marked":true}}
```

一个简单的报告显示了多少对象在每一次的GC世代中被保留，这是个非常好的查看内存泄漏的开始，这是对象泄漏的一条时间线。

```ruby
require 'json'
class Analyzer
  def initialize(filename)
    @filename = filename
  end

  def analyze
    data = []
    File.open(@filename) do |f|
      f.each_line do |line|
        data << (parsed=JSON.parse(line))
      end
    end

    data.group_by{|row| row["generation"]}
        .sort{|a,b| a[0].to_i <=> b[0].to_i}
        .each do |k,v|
          puts "generation #{k} objects #{v.count}"
        end
  end
end

Analyzer.new(ARGV[0]).analyze
```

以我得到的结果为例：

```txt
generation  objects 334181
generation 7 objects 6629
generation 8 objects 38383
generation 9 objects 2220
generation 10 objects 208
generation 11 objects 110
generation 12 objects 489
generation 13 objects 505
generation 14 objects 1297
generation 15 objects 638
generation 16 objects 748
generation 17 objects 1023
generation 18 objects 805
generation 19 objects 407
generation 20 objects 126
generation 21 objects 1708
generation 22 objects 369
...
```

我们预期在进程启动后和偶尔引用新依赖时持有大量的对象，然而我们并不期望分配一致数量的对象并从不清理它们。让我们详细查看一个特定的世代：

```ruby
require 'json'
class Analyzer
  def initialize(filename)
    @filename = filename
  end

  def analyze
    data = []
    File.open(@filename) do |f|
        f.each_line do |line|
          parsed=JSON.parse(line)
          data << parsed if parsed["generation"] == 18
        end
    end
    data.group_by{|row| "#{row["file"]}:#{row["line"]}"}
        .sort{|a,b| b[1].count <=> a[1].count}
        .each do |k,v|
          puts "#{k} * #{v.count}"
        end
  end
end

Analyzer.new(ARGV[0]).analyze
```
```txt
generation 19 objects 407
/usr/local/lib/ruby/2.2.0/weakref.rb:87 * 144
/var/www/discourse/vendor/bundle/ruby/2.2.0/gems/therubyracer-0.12.1/lib/v8/weak.rb:21 * 72
/var/www/discourse/vendor/bundle/ruby/2.2.0/gems/therubyracer-0.12.1/lib/v8/weak.rb:42 * 72
/var/www/discourse/lib/freedom_patches/translate_accelerator.rb:65 * 15
/var/www/discourse/vendor/bundle/ruby/2.2.0/gems/i18n-0.7.0/lib/i18n/interpolate/ruby.rb:21 * 15
/var/www/discourse/lib/email/message_builder.rb:85 * 9
/var/www/discourse/vendor/bundle/ruby/2.2.0/gems/actionview-4.1.9/lib/action_view/template.rb:297 * 6
/var/www/discourse/lib/email/message_builder.rb:36 * 6
/var/www/discourse/lib/email/message_builder.rb:89 * 6
/var/www/discourse/lib/email/message_builder.rb:46 * 6
/var/www/discourse/lib/email/message_builder.rb:66 * 6
/var/www/discourse/vendor/bundle/ruby/2.2.0/gems/activerecord-4.1.9/lib/active_record/connection_adapters/postgresql_adapter.rb:515 * 5
```

更进一步，我们可以追踪对象的引用路径来查看谁引用了各种对象，并且重建对象图。

我在这个特殊情况下注意到的第一件事是我写的代码(???)，这是Rails本地化的猴补丁。

## Why we monkey patch rails localization?

在Discourse中我们出于2个原因对Rails本地化子系统进行了猴补丁：

1. 早期我们发现它很慢，需要更好的性能。
2. 最近我们开始积累大量的翻译，并且需要确保我们只按需加载翻译以降低内存使用率。 （这节省了我们20MB的RSS）

考虑下面这个工作：

```ruby
ENV['RAILS_ENV'] = 'production'
require 'benchmark/ips'

require File.expand_path("../../config/environment", __FILE__)

Benchmark.ips do |b|
  b.report do |times|
    i = -1
    I18n.t('posts') while (i+=1) < times
  end
end
```

在打猴补丁之前

```shell
sam@ubuntu discourse % ruby bench.rb
Calculating -------------------------------------
                         4.518k i/100ms
-------------------------------------------------
                        121.230k (±11.0%) i/s -    600.894k
```

在打猴补丁之后

```shell
sam@ubuntu discourse % ruby bench.rb
Calculating -------------------------------------
                        22.509k i/100ms
-------------------------------------------------
                        464.295k (±10.4%) i/s -      2.296M
```

就是说我们的国际化系统的速度快了4倍，但是……它泄漏内存。


重审代码后我发现了错误的代码行 [discourse](https://github.com/discourse/discourse/blob/3c6aede1aa98a8456b00ab2d1e01b3f35466323c/lib/freedom_patches/translate_accelerator.rb#L65)：

```ruby
    # load it
    I18n.backend.load_translations(I18n.load_path.grep Regexp.new("\\.#{locale}\\.yml$"))

    @loaded_locales << locale
  end
end

def translate(*args)
  @cache ||= LruRedux::ThreadSafeCache.new(LRU_CACHE_SIZE)
  found = true
  k = [args, config.locale, config.backend.object_id] # ----------------------------- 这一行
  t = @cache.fetch(k) { found = false }
  unless found
    load_locale(config.locale) unless @loaded_locales.include?(config.locale)
    begin
      t = translate_no_cache(*args)
    rescue MissingInterpolationArgument
      options = args.last.is_a?(Hash) ? args.pop.dup : {}
      options.merge!(locale: config.default_locale)
      key = args.shift
      t = translate_no_cache(key, options)
```

结果，我们从包含ActiveRecord对象的电子邮件消息构建器发送哈希值(???)，这个哈希随后被用作缓存的键值，而此缓存允许2000项条目。考虑到每个条目都可能涉及到大量的ActiveRecord对象，内存泄漏就非常严重。

为减轻内存压力，我更改了键值的构成策略，压缩了缓存并且完全绕过复杂的本地化：[pull request](https://github.com/discourse/discourse/commit/830ce05fe64fd310d26d7da87ea6e4076696b7c8#diff-27e12e440c4032dade41a92dae381e51)

一天之后再看内存图表可以轻松观察到此更改的影响

![](https://discuss.samsaffron.com/uploads/default/_optimized/ea3/b24/d4e46ac88e_690x257.png)

虽然没有阻止内存的泄漏，但很明确，泄漏速度慢下来了。

### therubyracer is leaking

在我们列表顶部我们看见JavaScript引擎[therubyracer](https://github.com/cowboyd/therubyracer)泄漏了很多对象，特别是它使用弱引用去维持Ruby到JavaScript的映射被持有太久了。

为了保持Discourse将Markdown转换为HTML的性能，我们保留了JavaScript引擎上下文。该引擎的启动太耗资源，所以当我们编辑帖子时我们在内存总保留了它(???)。

由于我们的代码相当孤立，因此repro(reproduce?)是微不足道的，首先我们用[memory_profiler](https://github.com/SamSaffron/memory_profiler)gem看看我们泄漏了多少对象。

```ruby
NV['RAILS_ENV'] = 'production'
require 'memory_profiler'
require File.expand_path("../../config/environment", __FILE__)

# warmup
3.times{PrettyText.cook("hello world")}

MemoryProfiler.report do
  50.times{PrettyText.cook("hello world")}
end.pretty_print
```

在报告的顶部可以看到:

```txt
retained objects by location
-----------------------------------
       901  /home/sam/.rbenv/versions/2.1.2.discourse/lib/ruby/2.1.0/weakref.rb:87
       901  /home/sam/.rbenv/versions/2.1.2.discourse/lib/ruby/gems/2.1.0/gems/therubyracer-0.12.1/lib/v8/weak.rb:21
       600  /home/sam/.rbenv/versions/2.1.2.discourse/lib/ruby/gems/2.1.0/gems/therubyracer-0.12.1/lib/v8/weak.rb:42
       250  /home/sam/.rbenv/versions/2.1.2.discourse/lib/ruby/gems/2.1.0/gems/therubyracer-0.12.1/lib/v8/context.rb:97
        50  /home/sam/.rbenv/versions/2.1.2.discourse/lib/ruby/gems/2.1.0/gems/therubyracer-0.12.1/lib/v8/object.rb:8
```

所以我们每次编辑一个帖子就泄漏了54（(901+901+600+250+50)/50.times）个对象，这增长太快了。我们还可能在这里泄漏了unmanaged的内存，这复杂化了问题。

由于我们有代码行，所以很简单的就追踪到了泄漏的位置

```ruby
require 'weakref'
class Ref
  def initialize(object)
    @ref = ::WeakRef.new(object)
  end
  def object
    @ref.__getobj__
  rescue ::WeakRef::RefError
    nil
  end
end

class WeakValueMap
   def initialize
      @values = {}
   end

   def [](key)
      if ref = @values[key]
        ref.object
      end
   end

   def []=(key, value)
     @values[key] = V8::Weak::Ref.new(value)
   end
end
```

这个`WeakValueMap`对象保持永远增长并且它的对象不会被清理。使用`WeakRef`的目的是为确保我们允许当对象不被引用时会被清理掉。麻烦是对此封装的引用现在保持在JavaScript上下文的整个生命期。

修复很直接：

```ruby
class WeakValueMap
  def initialize
    @values = {}
  end

  def [](key)
    if ref = @values[key]
      ref.object
    end
  end

  def []=(key, value)
    ref = V8::Weak::Ref.new(value)
    ObjectSpace.define_finalizer(value, self.class.ensure_cleanup(@values, key, ref))

    @values[key] = ref
  end

  def self.ensure_cleanup(values,key,ref)
    proc {
      values.delete(key) if values[key] == ref
    }
  end
end
```

我们在被封装的对象上定义了一个析构函数，以确保我们清理这些被封装的对象，保持`WeakValueMap`小一点。

效果惊人：

```ruby
ENV['RAILS_ENV'] = 'production'
require 'objspace'
require 'memory_profiler'
require File.expand_path("../../config/environment", __FILE__)

def rss
 `ps -eo pid,rss | grep #{Process.pid} | awk '{print $2}'`.to_i
end

PrettyText.cook("hello world")

# MemoryProfiler has a helper that runs the GC multiple times to make sure all objects that can be freed are freed.
# MemoryProfiler 有一个辅助方法会运行GC很多次，确保所有能被释放的对象都释放掉
MemoryProfiler::Helpers.full_gc
puts "rss: #{rss} live objects #{GC.stat[:heap_live_slots]}"

20.times do

  5000.times { |i|
    PrettyText.cook("hello world")
  }
  MemoryProfiler::Helpers.full_gc
  puts "rss: #{rss} live objects #{GC.stat[:heap_live_slots]}"

end
```

**优化之前**：

```text
rss: 137660 live objects 306775
rss: 259888 live objects 570055
rss: 301944 live objects 798467
rss: 332612 live objects 1052167
rss: 349328 live objects 1268447
rss: 411184 live objects 1494003
rss: 454588 live objects 1734071
rss: 451648 live objects 1976027
rss: 467364 live objects 2197295
rss: 536948 live objects 2448667
rss: 600696 live objects 2677959
rss: 613720 live objects 2891671
rss: 622716 live objects 3140339
rss: 624032 live objects 3368979
rss: 640780 live objects 3596883
rss: 641928 live objects 3820451
rss: 640112 live objects 4035747
rss: 722712 live objects 4278779
/home/sam/Source/discourse/lib/pretty_text.rb:185:in `block in markdown': Script Timed Out (PrettyText::JavaScriptError)
	from /home/sam/Source/discourse/lib/pretty_text.rb:350:in `block in protect'
	from /home/sam/Source/discourse/lib/pretty_text.rb:348:in `synchronize'
	from /home/sam/Source/discourse/lib/pretty_text.rb:348:in `protect'
	from /home/sam/Source/discourse/lib/pretty_text.rb:161:in `markdown'
	from /home/sam/Source/discourse/lib/pretty_text.rb:218:in `cook'
	from tmp/mem_leak.rb:30:in `block (2 levels) in <main>'
	from tmp/mem_leak.rb:29:in `times'
	from tmp/mem_leak.rb:29:in `block in <main>'
	from tmp/mem_leak.rb:27:in `times'
	from tmp/mem_leak.rb:27:in `<main>'
```

**优化之后**：

```text
rss: 137556 live objects 306646
rss: 259576 live objects 314866
rss: 261052 live objects 336258
rss: 268052 live objects 333226
rss: 269516 live objects 327710
rss: 270436 live objects 338718
rss: 269828 live objects 329114
rss: 269064 live objects 325514
rss: 271112 live objects 337218
rss: 271224 live objects 327934
rss: 273624 live objects 343234
rss: 271752 live objects 333038
rss: 270212 live objects 329618
rss: 272004 live objects 340978
rss: 270160 live objects 333350
rss: 271084 live objects 319266
rss: 272012 live objects 339874
rss: 271564 live objects 331226
rss: 270544 live objects 322366
rss: 268480 live objects 333990
rss: 271676 live objects 330654
```

修复后看起来内存稳定，活动对象数稳定。相关的[pull request](https://github.com/cowboyd/therubyracer/pull/336)。

## 总结

Ruby现有的工具提供了了查看Ruby运行时的极佳可视性，围绕这种新设施的工具还在改进中但仍然相当粗糙。

作为一个之前生涯都是.NET的程序员我真的很想念那优异的[内存探查](http://memprofiler.com/)工具，幸运的是我们现在有创建此类工具所有需要的信息。

祝你在捕捉内存泄漏时好运，我希望本文能帮助你，**请**在下次部署**unicorn OOM killer**时三思。

非常感谢[Koichi Sasada](http://www.atdot.net/~ko1/)和[Aman Gupta](http://tmm1.net/)为我们创造了新的内存探测基础工具。

PS：另一个值得阅读的优秀资源是Oleg Dashevskii的[How I spent two weeks hunting a memory leak in Ruby](http://www.be9.io/2015/09/21/memory-leak/)。

----

不是非常有把握的翻译：

- 1. 
  - [managed/unmanaged] memory leak
  - 保留的英文原文，「托管/非托管」的内存泄漏？是说的「自己代码」和「第三方代码」？还是说「Ruby代码」和「C扩展代码」？拿不准，就保留原文了。
- 2.
  - This container is launched with access to the Docker socket so it can interrogate Docker about Docker.
  - 这个定制的容器启动后能访问Docker套接字，所以它能够询问Docker关于Docker的问题。
- 3.
  - it is impossible to achieve the same setup (which shares memory among forks) in a one container per process world.
  - 这不可能由单进程单容器的方式达成（在分支间共享内存）。
- 4.
  - It is much simpler to isolate that a trend started after upgrading EventMachine to version 1.0.5.
  - 在[升级EventMachine](https://github.com/eventmachine/eventmachine/pull/586)后，隔离趋势开始变得更加简单。
- 5.
  - a nifty trick is breaking out of the trap context with Thread.new
  - 一个巧妙的技巧是用`Thread.new`来突破陷阱环境
- 6.
  - The GC generation it was allocated in
  - 分配给它的GC世代
- 7.
  - The first thing I attacked in this particular case was code I wrote, which is a monkey patch to Rails localization.
  - 我在这个特殊情况下注意到的第一件事是我写的代码，这是Rails本地化的猴子补丁。
- 8.
  - we were sending a hash in from the email message builder that includes ActiveRecord objects
  - 我们从包含ActiveRecord对象的电子邮件消息构建器发送哈希值
- 9.
  - so we keep it in memory plugging in new variables as we bake posts.
  - 所以当我们编辑帖子时我们在内存总保留了它
- 10.
  - Running Ruby in an already running process
  - 这一句根据上下文我读出来的是类似「attach to a running Ruby process and debug」，不知道怎么翻译原文
