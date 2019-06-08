module OFX
  module Parser
    class OFX102
      VERSION = "1.0.2"

      ACCOUNT_TYPES = {
        "CHECKING" => :checking,
        "SAVINGS"  => :savings,
        "CREDITLINE" => :creditline,
        "MONEYMRKT" => :moneymrkt
      }

      TRANSACTION_TYPES = [
        'ATM', 'CASH', 'CHECK', 'CREDIT', 'DEBIT', 'DEP', 'DIRECTDEBIT', 'DIRECTDEP', 'DIV',
        'FEE', 'INT', 'OTHER', 'PAYMENT', 'POS', 'REPEATPMT', 'SRVCHG', 'XFER'
      ].inject({}) { |hash, tran_type| hash[tran_type] = tran_type.downcase.to_sym; hash }

      SEVERITY = {
        "INFO" => :info,
        "WARN" => :warn,
        "ERROR" => :error
      }

      attr_reader :headers
      attr_reader :body
      attr_reader :html

      def initialize(options = {})
        @headers = options[:headers]
        @body = options[:body]
        @html = Nokogiri::HTML.parse(body)
      end

      def statements
        @statements ||= html.search("stmttrnrs, ccstmttrnrs, invstmttrnrs").collect { |node| build_statement(node) }
      end

      def accounts
        @accounts ||= html.search("stmttrnrs, ccstmttrnrs, invstmttrnrs").collect { |node| build_account(node) }
      end

      # DEPRECATED: kept for legacy support
      def account
        @account ||= build_account(html.search("stmttrnrs, ccstmttrnrs, invstmttrnrs").first)
      end

      def sign_on
        @sign_on ||= build_sign_on
      end

      def self.parse_headers(header_text)
        # Change single CR's to LF's to avoid issues with some banks
        header_text.gsub!(/\r(?!\n)/, "\n")

        # Parse headers. When value is NONE, convert it to nil.
        headers = header_text.to_enum(:each_line).inject({}) do |memo, line|
          _, key, value = *line.match(/^(.*?):(.*?)\s*(\r?\n)*$/)

          unless key.nil?
            memo[key] = value == "NONE" ? nil : value
          end

          memo
        end

        return headers unless headers.empty?
      end

      private

      def build_statement(node)
        stmrs_node = node.search("stmtrs, ccstmtrs, invstmtrs")
        account = build_account(node)
        OFX::Statement.new(
          :currency          => stmrs_node.search("curdef").inner_text,
          :start_date        => build_date(stmrs_node.search("banktranlist > dtstart, invtranlist > dtstart").inner_text),
          :end_date          => build_date(stmrs_node.search("banktranlist > dtend, invtranlist > dtstart").inner_text),
          :account           => account,
        )
      end

      def build_account(node)
        OFX::Account.new({
          :bank_id           => node.search("bankacctfrom > bankid").inner_text,
          :id                => node.search("bankacctfrom > acctid, ccacctfrom > acctid, invacctfrom > acctid").inner_text,
          :type              => ACCOUNT_TYPES[node.search("bankacctfrom > accttype").inner_text.to_s.upcase],
          :transactions      => build_transactions(node),
          :inv_transactions  => build_invtransactions(node),
          :balance           => build_balance(node),
          :available_balance => build_available_balance(node),
          :currency          => node.search("stmtrs > curdef, ccstmtrs > curdef, invstmtrs > curdef").inner_text
        })
      end

      def build_status(node)
        OFX::Status.new({
          :code              => node.search("code").inner_text.to_i,
          :severity          => SEVERITY[node.search("severity").inner_text],
          :message           => node.search("message").inner_text,
        })
      end

      def build_sign_on
        OFX::SignOn.new({
          :language          => html.search("signonmsgsrsv1 > sonrs > language").inner_text,
          :fi_id             => html.search("signonmsgsrsv1 > sonrs > fi > fid").inner_text,
          :fi_name           => html.search("signonmsgsrsv1 > sonrs > fi > org").inner_text,
          :status            => build_status(html.search("signonmsgsrsv1 > sonrs > status"))
        })
      end

      def build_transactions(node)
        node.search("banktranlist > stmttrn, invtranlist > invbanktran > stmttrn").collect do |element|
          build_transaction(element)
        end
      end

      def build_invtransactions(node)
        types = %w[
          buydebt buymf buyopt buyother buystock
          closureopt
          income
          invexpense
          jrnlfund jrnlsec
          margininterest
          reinvest
          retofcap
          selldebt sellmf sellopt sellstock
          split
          transfer
        ]
        node.search(types.map{|t| "invtranlist > #{t}"}.join ', ').collect do |element|
          build_invtransaction(element)
        end
      end

      def build_transaction(element)
        occurred_at = build_date(element.search("dtuser").inner_text) rescue nil

        OFX::Transaction.new({
          :amount            => build_amount(element),
          :amount_in_pennies => (build_amount(element) * 100).to_i,
          :fit_id            => element.search("fitid").inner_text,
          :memo              => element.search("memo").inner_text,
          :name              => element.search("name").inner_text,
          :payee             => element.search("payee").inner_text,
          :check_number      => element.search("checknum").inner_text,
          :ref_number        => element.search("refnum").inner_text,
          :posted_at         => build_date(element.search("dtposted").inner_text),
          :occurred_at       => occurred_at,
          :type              => build_type(element),
          :sic               => element.search("sic").inner_text
        })
      end

      def build_invtransaction(element)
        OFX::InvTransaction.new({
          :type        => element.name,
          :fit_id      => element.search("invtran > fitid").inner_text,
          :memo        => element.search("invtran > memo").inner_text,
          :traded_at   => build_date(element.search("invtran > dttrade").inner_text),
          :settled_at  => build_date(element.search("invtran > dtsettle").inner_text),
          :cusip_secid => element.search("secid > uniqueid").inner_text,
          :units       => opt(element.search('units').inner_text){|u| to_decimal u},
          :total       => opt(element.search('total').inner_text){|t| to_decimal t},
          :inv_401k_source => opt(element.search('inv401ksource').inner_text),
        })
      end

      def opt(v, &block)
        v && v != "" ? (block ? block.call(v) : v) : nil
      end

      def build_type(element)
        TRANSACTION_TYPES[element.search("trntype").inner_text.to_s.upcase]
      end

      def build_amount(element)
        to_decimal(element.search("trnamt").inner_text)
      end

      # Input format is `YYYYMMDDHHMMSS.XXX[gmt offset[:tz name]]`
      def build_date(date)
        tz_pattern = /(?:\[([+-]?\d{1,4})\:\S{3}\])?\z/

        # Timezone offset handling
        date.sub!(tz_pattern, '')
        offset = Regexp.last_match(1)

        if offset
          # Offset padding
          _, hours, mins = *offset.match(/\A([+-]?\d{1,2})(\d{0,2})?\z/)
          offset = "%+03d%02d" % [hours.to_i, mins.to_i]
        else
          offset = "+0000"
        end

        date << " #{offset}"

        Time.parse(date)
      end

      def build_balance(node)
        if node.search("ledgerbal").size > 0
          amount = to_decimal(node.search("ledgerbal > balamt").inner_text)
          posted_at = build_date(node.search("ledgerbal > dtasof").inner_text) rescue nil

          OFX::Balance.new({
            :amount => amount,
            :amount_in_pennies => (amount * 100).to_i,
            :posted_at => posted_at
          })
        else
          nil
        end
      end

      def build_available_balance(node)
        if node.search("availbal").size > 0
          amount = to_decimal(node.search("availbal > balamt").inner_text)

          OFX::Balance.new({
            :amount => amount,
            :amount_in_pennies => (amount * 100).to_i,
            :posted_at => build_date(node.search("availbal > dtasof").inner_text)
          })
        else
          return nil
        end
      end

      def to_decimal(amount)
        BigDecimal.new(amount.to_s.gsub(',', '.'))
      end
    end
  end
end
