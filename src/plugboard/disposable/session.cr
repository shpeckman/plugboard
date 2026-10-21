# src/plugboard/disposable/session.cr
class Plugboard::Session
  include Disposable

  @undo : (-> Nil)?

  def initialize(@owner : Context, @setup : -> (-> Nil))
    @undo     = nil
    @disposed = false
  end

  def start : Nil
    return if @undo || @disposed
    @undo = @setup.call
  end

  def stop : Nil
    undo  = @undo || return
    @undo = nil
    undo.call
  end

  def dispose : Nil
    return if @disposed
    @disposed = true
    begin
      stop
    ensure
      @owner.app.detach(self)
      @owner.disown(self)
    end
  end
end
