# How Ruby Uses Memory

- Origin Post: https://www.sitepoint.com/ruby-uses-memory/
- 原文[创作时间 2015-5-11]: https://www.sitepoint.com/ruby-uses-memory/

我从未遇到哪个开发者抱怨代码执行得太快或使用了太少内存。对于Ruby而言，内存尤其重要，但几乎没有开发者知道他们代码执行过程中内存上升或下降的来龙去脉。本文将开始带你理解Ruby对象和内存使用的关系，另外有几个利用更少内存并加速代码执行的通用技巧。

## 对象保留

Ruby占用更多内存的明显方法是持有对象(retaining objects)。Ruby永远不回收(GC)常量(constants)，所以如果一个常量引用了一个对象，那么此对象也永远不会被GC。

```ruby
RETAINED = []
100_000.times do
  RETAINED << "a string"
end
```

如果我们用 `GC.stat(:total_freed_objects)` 调试运行这段脚本，它将返回Ruby释放的对象数量。在其前后添加一点点变化：

```ruby
# Ruby 2.2.2

GC.start
before = GC.stat(:total_freed_objects)

RETAINED = []
100_000.times do
  RETAINED << "a string"
end

GC.start
after = GC.stat(:total_freed_objects)
puts "Objects Freed: #{after - before}"

# => "Objects Freed: 6
```

我就创建了 10W 个 `"a string"` 的拷贝，但因为我们 **可能** 在未来使用这些变量，所以他们无法被GC。当对象被一个 全局变量、常量、模块(module)、类(class) 引用时是无法被GC的。从这些东西去引用对象的时候需要格外小心。

如果我们创建对象却不持有它们呢：

```ruby
100_000.times do
  foo = "a string"
end
```

被释放的对象数量马上飙升 `Objects Freed: 100005`。你同样可以验证其内存使用是非常小的：6MB左右，之前引用了它们时是12MB。如果你愿意，可以用 [get_process_mem gem](https://github.com/schneems/get_process_mem) 测量它。

对象保留可以进一步用 `GC.stat(:total_allocated_objects)` 来验证，然后被保留的数量等同于 `total_allocated_objects - total_freed_objects`。

## 为速度保留对象

Ruby开发者都熟悉 DRY(Don't repeat yourself)原则，在 *对象分配* 这一事上它同样是真理。有时，*保留对象以复用* 比一遍遍的创建它们更合理。Ruby内建的`String`就有这一功能，如果你为一个字符串调用了 `call` 方法，解释器就理解你没有计划更改这个字符串，它就能被复用了。例子：

```ruby
RETAINED = []
100_000.times do
  RETAINED << "a string".freeze
end
```

运行这个脚本，你将得到 `Objects Freed: 6`，但是内存使用将非常的少。用 `GC.stat(:total_allocated_objects)` 验证它，因为服用只有很少的对象被分配为 `"a string"`。

有别于存储 10W 个不同的对象，Ruby可以仅存储一个对象，但有 10W 个引用指向它。除了减少内存，执行时间同样减少了，因为Ruby可以花更少的时间去创建对象和分配内存。如果你愿意，可以用 [benchmark-ips](https://github.com/evanphx/benchmark-ips) 双重验证一下。

类似Ruby内置的这种重复删除常用字符串的方法，你可以通过把任何对象赋值给常量。这是一个存储外部连接的通用模式，比如 Redis：

```ruby
RETAINED_REDIS_CONNECTION = Redis.new
```

由于常量引用到了 Redis 连接，它将永远不会被GC。有时小心的保留对象是有意思的，我们可以降低内存使用。

## 短命的对象

大多数对象都是短命的，这意味着当它们创建后不久就将没有被引用，例如，看看这个代码：

```ruby
User.where(name: "schneems").first
```

表面上看，它好像需要一些对象来工作（那个Hash、符号`:name`，还有`"schneems"`字符串）。然而，当你调用它，非常多的中间对象被创建处理以生成正确的SQL语句，使用预声明语句是可以的，还有其他。其中的很多对象仅在方法执行过程中存活，如果这些对象将不被保留，为何我们要关注它们的创建？

产生中等数量的中长期存活对象将导致你的内存随时间推移而升高，如果垃圾回收开始的时刻，这些对象被引用了，那将导致Ruby的垃圾回收需要更多的内存。

## Ruby内存攀升

当你使用的对象不能被Ruby放入当前内存时，它必须要占用额外的内存。向操作系统请求内存是个重操作，因此Ruby尽量减少做这事。不同于每次拿几KB，它每次会拿比它目前需要的更大一些的内存。你可以通过环境变量`RUBY_GC_HEAP_GROWTH_FACTOR`来设置这个数量。

举例，如果Ruby使用了100MB，并且你设置了`RUBY_GC_HEAP_GROWTH_FACTOR=1.1`，那么，当Ruby再次请求内存时，它将拿110MB。当一个Ruby应用启动后，它将保持使用通用的比率来获取内存，直到整个程序可以在分配的内存里执行。一个更低的数值意味着我们必须更频繁的运行GC和请求内存，但也会更慢一点的到达最大的内存使用。而一个更高的数值则意味着更少的GC，但可能拿了比所需更多的内存。

为了优化网站，很多开发者倾向于认为「Ruby永远不释放内存」，这并不是真理，因为Ruby会释放内存的。我们随后将讨论这个。

如果你考虑这些行为，非保留对象将如何影响内存使用会更有意义，例如：

```ruby
def make_an_array
  array = []
  10_000_000.times do
    array <<  "a string"
  end
  return nil
end
```

当我们调用这个方法，1KW 字符串被创建。当此方法退出时，这些字符串没有被任何对象引用，于是会被GC。不过，当程序运行时，Ruby必须为这1KW字符串请求内存。这需要500MB。

如果你剩下的应用程序只需10MB也没办法，该进程必须要求500MB的RAM的创建此数组。当然这是一个不重要的例子，想象一下当Ruby进程在一个真实的Rails大页面请求过程中耗尽了内存，此时Ruby如果不能收集到足够的内存槽，那GC被触发，同时向OS请求更多的内存。

由于向OS请求内存是昂贵的，Ruby会持有已分配的内存一段时间。如果进程曾经使用了那么大的内存，那它可能会再次使用。已持有的内存会逐渐被释放，但很缓慢。如果你关注程序性能，那最好尽可能的最小化对象创建热点。

## 提速：就地修改 In-Place Modification for Speed 

我曾经使用过的程序加速+减少对象创建的一个小技巧是「用既有对象的状态更改来代替新对象创建」。例如，这是一段 [mime-types gem](https://github.com/halostatue/mime-types) 里的代码：

```ruby
matchdata.captures.map { |e|
  e.downcase.gsub(%r{[Xx]-}o, '')
end
```

这段代码从正则表达式的`match`方法拿到一个`matchdata`对象，然后为匹配结果生成一个数组然后传入block，这个block把字符串弄成小写并移除一些字符。它看起来是个完美合理的代码，只是，当`mime-types` gem被require时它将被调用上千次。每一次执行到`downcase`和`gsub`的时候都创建了新的字符串对象，这消耗了时间和内存。为了避免这个情况，我们可以做个简单的就地更改：

```ruby
matchdata.captures.map { |e|
  e.downcase!
  e.gsub!(%r{[Xx]-}o, ''.freeze)
  e
}
```

这个结果当然更冗长了点，但它快得多。这个技巧可行是因为我们没有引用传入该block的原始字符串，所以如果我们更改就有字符串而非新建一个就没关系了。

注：你不需要用常量来保存正则表达式，所有的正则表达式都被Ruby解释器认为是`frozen`的。

就地修改是个你很容易惹到麻烦的方法。我们很容易去修改一个你都没意识到在其他地方使用了的变量，这会导致微妙并难以找到的回归（？）。在做这一类的优化时，确保你有良好的测试。还有，只优化那些经过你测定的创建了极其大量对象的「热点」区域。

认为「对象很缓慢」是个误解。正确的使用对象能让程序更易于理解和优化。就算是最快的工具和技术，如果使用不妥当，也会导致程序缓慢。

一个好的捕捉非必要的对象创建的方法是在应用层使用[derailed_benchmarks gem](https://github.com/schneems/derailed_benchmarks)。在低级层，则使用[allocation_tracer gem](https://github.com/ko1/allocation_tracer)或者[memory_profiler gem](https://github.com/SamSaffron/memory_profiler)。

注：我（原作者）开发的 derailed_benchmarks gem，用 `rake perf:mem` 查看内存使用统计。

## Good to be Free

前面提到，Ruby会释放内存，但是很慢。在运行了导致我们内存膨胀的`make_an_array`方法后，你可以这样观察Ruby释放内存：

```ruby
while true
  GC.start
end
```

非常的慢，应用程序的内存会下降。当有太多内存被占用后，Ruby每次释放少量的内存空页（一组内存槽slot）。操作系统调用`malloc`，用来分配内存，同样会把内存释放归还给操作系统，这取决于操作系统特有的malloc库的实现。

对于大多数应用程序，如网站，导致内存攀升的操作可以是某个页面被访问。当这个页面被频繁访问时，我们不能依赖于Ruby释放内存来保证网站的小足迹。同样，释放内存需要时间，我们最好在热点区域最小化对象的创建。

## 毕业 You're Up

现在你拥有理解Ruby如何试用内存的坚实基础了，可以回到现场去开始衡量了。可以使用这几个工具：

- [derailed_benchmarks](https://github.com/schneems/derailed_benchmarks)
- [allocation_tracer](https://github.com/ko1/allocation_tracer)
- [memory_profiler](https://github.com/SamSaffron/memory_profiler)
- [benchmark-ips](https://github.com/evanphx/benchmark-ips)

然后给一些代码做基准，如果你不能找到任何基准，尝试一下重现本文的结果。一旦掌握了这一点，尝试挖掘自己的代码并找到对象创建的热点区域。它可能是你写的也可能是第三方的gem。一旦找到热点区域，尝试优化它。重复这个模式：找热点区域，优化它，再评估。是时候调教你的宝石了。

----

如果你对Ruby内存统计的推文感兴趣，可以关注 [@schneems](https://twitter.com/schneems)

----

不是非常有把握的翻译：

- 1
  - If you take these behaviors into account, it might make more sense how non-retained objects can have an impact on overall memory use. For example:
  - 如果你考虑这些行为，非保留对象将如何影响内存使用会更有意义，例如：

- 2
  - The operating system call to `malloc`, which is currently used to allocate memory
  - 操作系统调用`malloc`，用来分配内存

- 3
  - we cannot rely on Ruby’s ability to free memory to keep our application footprint small
  - 我们不能依赖于Ruby释放内存来保证网站的小足迹

