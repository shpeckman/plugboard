# src/plugboard/token.cr
class Plugboard::Token
  def initialize
    @cancelled = Atomic(Bool).new(false)
  end

  def cancel : Nil
    @cancelled.set(true)
  end

  def cancelled? : Bool
    @cancelled.get
  end
end
