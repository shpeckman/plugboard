# src/plugboard/context.cr
class Plugboard::Context
  include Disposable
  include Scope

  getter app    : App
  getter parent : Context?

  def initialize(@app : App, @parent : Context? = nil)
    @held     = [] of Disposable?
    @holes    = 0
    @disposed = false
  end

  def scope : Context
    self
  end

  def disposed? : Bool
    @disposed
  end

  def own(item : T) : T forall T
    {% for member in (T.union? ? T.union_types : [T]) %}
      {% raise "plugboard: #{member} must include Plugboard::Disposable to be owned" unless member <= ::Plugboard::Disposable %}
    {% end %}
    @app.assert_loop
    if @disposed
      item.dispose
    else
      item.held_index = @held.size
      @held << item
    end
    item
  end

  def disown(item : Disposable) : Nil
    @app.assert_loop
    return if @disposed

    index = item.held_index
    return unless index >= 0 && @held[index]?.same?(item)

    @held[index] = nil
    item.held_index = -1
    @holes += 1
    compact if @holes * 2 > @held.size
  end

  def dispose : Nil
    return if @disposed
    @app.assert_loop
    @disposed = true
    failure   = nil.as(Exception?)
    until @held.empty?
      item = @held.pop || next
      item.held_index = -1
      begin
        item.dispose
      rescue error
        failure ||= error
      end
    end
    @holes = 0
    @parent.try(&.disown(self))
    raise failure if failure
  end

  private def compact : Nil
    kept = 0
    @held.each do |entry|
      next unless entry
      entry.held_index = kept
      @held[kept] = entry
      kept += 1
    end
    @held.truncate(0, kept)
    @holes = 0
  end
end
