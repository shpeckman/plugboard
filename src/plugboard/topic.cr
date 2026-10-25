# src/plugboard/topic.cr
require "./roster"
require "./chain"

class Plugboard::Topic(T)
  def initialize
    @chain     = Chain(T).new
    @listeners = Roster(T -> Nil).new
    @handlers  = Roster(T -> Bool).new
    @observers = Roster(T, Bool -> Nil).new
    @chain.sink = ->(event : T) { deliver(event) }
  end

  def size : Int32
    @listeners.size + @handlers.size + @observers.size
  end

  def empty? : Bool
    @listeners.empty? && @handlers.empty? && @observers.empty?
  end

  def intercept(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    @chain.add(link)
  end

  def unintercept(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    @chain.remove(link)
  end

  def listen(listener : T -> Nil) : Nil
    @listeners.add(listener)
  end

  def unlisten(listener : T -> Nil) : Nil
    @listeners.remove(listener)
  end

  def handle(handler : T -> Bool) : Nil
    @handlers.add(handler)
  end

  def unhandle(handler : T -> Bool) : Nil
    @handlers.remove(handler)
  end

  def observe(observer : T, Bool -> Nil) : Nil
    @observers.add(observer)
  end

  def unobserve(observer : T, Bool -> Nil) : Nil
    @observers.remove(observer)
  end

  def emit(event : T) : Bool
    @chain.run(event)
  end

  def deliver(event : T) : Bool
    @listeners.each(&.call(event))
    taken = false
    @handlers.each do |handler|
      if handler.call(event)
        taken = true
        break
      end
    end
    @observers.each(&.call(event, taken))
    taken
  end
end
