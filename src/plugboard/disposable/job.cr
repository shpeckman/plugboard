# src/plugboard/disposable/job.cr
class Plugboard::Job
  include Disposable

  getter token : Token

  def initialize(@owner : Context)
    @token = Token.new
    @live  = true
  end

  def live? : Bool
    @live
  end

  def finish(& : -> Nil) : Nil
    return unless @live
    dispose
    yield
  end

  def fail(error : Exception) : Nil
    return unless @live
    dispose
    raise error
  end

  def dispose : Nil
    return unless @live
    @live = false
    @token.cancel
    @owner.disown(self)
  end
end
