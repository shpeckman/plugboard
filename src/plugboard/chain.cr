# src/plugboard/chain.cr
class Plugboard::Chain(T)
  property sink : T -> Bool

  def initialize
    @links = [] of Proc(T, Proc(T, Nil), Nil)
    @nexts = [] of Proc(T, Nil)
    @sink = ->(event : T) { false }
    @result = false
  end

  def empty? : Bool
    @links.empty?
  end

  def add(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    rebuild(@links + [link])
  end

  def remove(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    index = @links.index(link) || return
    links = @links.dup
    links.delete_at(index)
    rebuild(links)
  end

  def run(event : T) : Bool
    held = @result
    @result = false
    begin
      step(@links, @nexts, 0, event)
      @result
    ensure
      @result = held
    end
  end

  private def rebuild(links : Array(Proc(T, Proc(T, Nil), Nil))) : Nil
    nexts = Array(Proc(T, Nil)).new(links.size)
    links.size.times do |index|
      nexts << ->(event : T) { step(links, nexts, index + 1, event) }
    end
    @links = links
    @nexts = nexts
  end

  private def step(links : Array(Proc(T, Proc(T, Nil), Nil)), nexts : Array(Proc(T, Nil)),
                   index : Int32, event : T) : Nil
    if index < links.size
      links.unsafe_fetch(index).call(event, nexts.unsafe_fetch(index))
    else
      @result = @sink.call(event)
    end
  end
end
