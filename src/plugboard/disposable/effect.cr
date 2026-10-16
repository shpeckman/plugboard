# src/plugboard/disposable/effect.cr
class Plugboard::Effect
  include Disposable

  def initialize(@owner : Context, @undo : -> Nil)
    @disposed = false
  end

  def dispose : Nil
    return if @disposed
    @disposed = true
    @owner.disown(self)
    @undo.call
  end
end
