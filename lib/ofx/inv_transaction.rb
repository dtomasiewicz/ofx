module OFX
  class InvTransaction < Foundation
    attr_accessor :type
    attr_accessor :fit_id
    attr_accessor :memo
    attr_accessor :traded_at
    attr_accessor :settled_at
    attr_accessor :cusip_secid
    attr_accessor :units
    attr_accessor :total
    attr_accessor :inv_401k_source
  end
end
