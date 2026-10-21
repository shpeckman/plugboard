# src/plugboard/topic.cr
require "./chain"

class Plugboard::Topic(T)
  def initialize
    @chain = Chain(T).new
    @listeners = [] of T -> Nil
    @handlers = [] of T -> Bool
    @chain.sink = ->(event : T) { deliver(event) }
  end

  def size : Int32
    @listeners.size + @handlers.size
  end

  def empty? : Bool
    @listeners.empty? && @handlers.empty?
  end

  def intercept(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    @chain.add(link)
  end

  def unintercept(link : Proc(T, Proc(T, Nil), Nil)) : Nil
    @chain.remove(link)
  end

  def listen(listener : T -> Nil) : Nil
    @listeners = @listeners + [listener]
  end

  def unlisten(listener : T -> Nil) : Nil
    @listeners = @listeners.reject { |entry| entry == listener }
  end

  def handle(handler : T -> Bool) : Nil
    @handlers = @handlers + [handler]
  end

  def unhandle(handler : T -> Bool) : Nil
    @handlers = @handlers.reject { |entry| entry == handler }
  end

  def emit(event : T) : Bool
    @chain.run(event)
  end

  def deliver(event : T) : Bool
    @listeners.each(&.call(event))
    @handlers.each do |handler|
      return true if handler.call(event)
    end
    false
  end
end
