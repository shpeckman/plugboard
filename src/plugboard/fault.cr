# src/plugboard/fault.cr
class Plugboard::Fault < Exception
  getter primary   : Exception
  getter secondary : Exception

  def initialize(@primary : Exception, @secondary : Exception)
    super("#{@primary.message} (then: #{@secondary.message})", @primary)
  end
end
