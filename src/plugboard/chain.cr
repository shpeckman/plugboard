# src/plugboard/chain.cr
require "./roster"

class Plugboard::Chain(T)
  property sink : T -> Bool

  def initialize
    @links  = Roster(Proc(T, Proc(T, Nil), Nil)).new
    @steps  = [] of Proc(T, Proc(T, Nil), Nil)
    @nexts  = [] of Proc(T, Nil)
    @sink   = ->(event : T) { false }
    @result = false
  end

  def empty? : Bool
    @links.empty?
  end

  def add(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    @links.add(link)
    rebuild
  end

  def remove(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    rebuild if @links.remove(link)
  end

  def run(event : T) : Bool
    held    = @result
    @result = false
    begin
      step(@steps, @nexts, 0, event)
      @result
    ensure
      @result = held
    end
  end

  private def rebuild : Nil
    steps = @links.to_a
    nexts = Array(Proc(T, Nil)).new(steps.size)
    steps.size.times do |index|
      nexts << ->(event : T) { step(steps, nexts, index + 1, event) }
    end
    @steps = steps
    @nexts = nexts
  end

  private def step(steps : Array(Proc(T, Proc(T, Nil), Nil)), nexts : Array(Proc(T, Nil)),
                   index : Int32, event : T) : Nil
    if index < steps.size
      steps.unsafe_fetch(index).call(event, nexts.unsafe_fetch(index))
    else
      @result = @sink.call(event)
    end
  end
end
