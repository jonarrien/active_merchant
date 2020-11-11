require 'nokogiri'

module ActiveMerchant
  module Billing
    class KashingGateway < Gateway
      include Empty

      self.display_name = 'Kashing Limited'
      self.homepage_url = 'https://www.kashing.co.uk/'

      self.test_url = 'https://dev-api.kashing.co.uk'
      self.live_url = 'https://api.kashing.co.uk'

      self.supported_countries = %w(ES GB SE)
      self.default_currency = 'GBP'
      self.money_format = :cents
      self.supported_cardtypes = %i[visa master maestro]
      
      # Authorize.net has slightly different definitions for returned AVS codes
      # that have been mapped to the closest equivalent AM standard AVSResult codes
      # Authorize.net's descriptions noted below
      STANDARD_AVS_CODE_MAPPING = {
        'A' => 'A', # Street Address: Match -- First 5 Digits of ZIP: No Match
        'B' => 'I'  # Address not provided for AVS check or street address match
      }

      STANDARD_ERROR_CODE_MAPPING = {
        '2127' => STANDARD_ERROR_CODE[:incorrect_address],
        '22' => STANDARD_ERROR_CODE[:card_declined],
        '227' => STANDARD_ERROR_CODE[:incorrect_address],
        '23' => STANDARD_ERROR_CODE[:card_declined],
        '2315' => STANDARD_ERROR_CODE[:invalid_number],
        '2316' => STANDARD_ERROR_CODE[:invalid_expiry_date],
        '2317' => STANDARD_ERROR_CODE[:expired_card],
        '235' => STANDARD_ERROR_CODE[:processing_error],
        '237' => STANDARD_ERROR_CODE[:invalid_number],
        '24' => STANDARD_ERROR_CODE[:pickup_card],
        '244' => STANDARD_ERROR_CODE[:incorrect_cvc],
        '300' => STANDARD_ERROR_CODE[:config_error],
        '3153' => STANDARD_ERROR_CODE[:processing_error],
        '3155' => STANDARD_ERROR_CODE[:unsupported_feature],
        '36' => STANDARD_ERROR_CODE[:incorrect_number],
        '37' => STANDARD_ERROR_CODE[:invalid_expiry_date],
        '378' => STANDARD_ERROR_CODE[:invalid_cvc],
        '38' => STANDARD_ERROR_CODE[:expired_card],
        '384' => STANDARD_ERROR_CODE[:config_error]
      }

      MARKET_TYPE = {
        moto: '1',
        retail: '2'
      }

      DEVICE_TYPE = {
        unknown: '1',
        unattended_terminal: '2',
        self_service_terminal: '3',
        electronic_cash_register: '4',
        personal_computer_terminal: '5',
        airpay: '6',
        wireless_pos: '7',
        website: '8',
        dial_terminal: '9',
        virtual_terminal: '10'
      }

      class_attribute :duplicate_window

      APPROVED, DECLINED, ERROR, FRAUD_REVIEW = 1, 2, 3, 4
      TRANSACTION_ALREADY_ACTIONED = %w(310 311)

      CARD_CODE_ERRORS = %w(N S)
      AVS_ERRORS = %w(A E I N R W Z)
      AVS_REASON_CODES = %w(27 45)

      TRACKS = {
        1 => /^%(?<format_code>.)(?<pan>[\d]{1,19}+)\^(?<name>.{2,26})\^(?<expiration>[\d]{0,4}|\^)(?<service_code>[\d]{0,3}|\^)(?<discretionary_data>.*)\?\Z/,
        2 => /\A;(?<pan>[\d]{1,19}+)=(?<expiration>[\d]{0,4}|=)(?<service_code>[\d]{0,3}|=)(?<discretionary_data>.*)\?\Z/
      }.freeze

      APPLE_PAY_DATA_DESCRIPTOR = 'COMMON.APPLE.INAPP.PAYMENT'

      PAYMENT_METHOD_NOT_SUPPORTED_ERROR = '155'
      INELIGIBLE_FOR_ISSUING_CREDIT_ERROR = '54'

      def initialize(options = {})
        requires!(options, :merchant_id, :merchant_key)
        super
      end

      def purchase(amount, payment, options = {})
        puts 'Purchasing...'
        puts "  Amount:  #{amount}"
        puts "  Payment: #{payment}"
        puts "  Name:    #{payment.name}"
        puts "  Number:  #{payment.number}"
        puts "  Expiry:  #{payment.month}/#{payment.year}"
        puts "  CVV:     #{payment.verification_value}"
        puts "  Options: #{options}"
        response = init_transaction(options[:merchant_id], init_params(amount))
      end

      # --------------------------------------------------------------------------------
      #                                  HELPERS
      # --------------------------------------------------------------------------------

      def init_transaction(params)
        transaction_params = params.merge(merchantid: @options[:merchant_id], method: 1)
        transaction_params = transaction_params.merge!(psign: p_sign(transaction_params))
        commit('transaction/init', { transactions: [ transaction_params ] })
      end

      # --------------------------------------------------------------------------------
      #                                ^ HELPERS ^
      # --------------------------------------------------------------------------------

      def authorize(amount, payment, options = {})
        puts 'Authorizing...'
      end

      def capture(amount, authorization, options = {})
        puts 'Capturing...'
      end

      def refund(amount, authorization, options = {})
        puts 'Refunding...'
      end

      def void(authorization, options = {})
        puts 'Voiding...'
      end

      def credit(amount, payment, options = {})
        raise ArgumentError, 'Reference credits are not supported.'
      end

      def supports_scrubbing?
        false
      end

      def scrub(transcript)
        raise 'This gateway does not support scrubbing.'
      end

      private

      def init_params(amount)
        {
          merchantid: @options[:merchant_id],
          amount: amount.to_s,
          currency: 'GBP',
          savecard: 1,
          uid: '12345678',
          returnurl: 'https://shop.kashing.co.uk/',
          description: 'ActiveMerchant test',
          email: 'gitlab-ci@gmail.com',
          firstname: 'Sarah',
          lastname: 'Connor',
          phone: '44 123 123 123',
          address1: 'Vintage House',
          address2: 'Albert Embankment 37',
          city: 'London',
          postcode: 'SE1 7TL',
          country: 'United Kingdom',
          processtype: 1
        }
      end

      def commit(action, params, reference_action = nil)
        json = params.to_json
        full_url = "#{url}/#{action}"
        puts "[POST] #{full_url}"
        puts json
        raw_response = ssl_post(full_url, json)
        response = JSON.parse(raw_response)
        puts "[RSP] #{response}"

        Response.new(
            success_from(response),
            message_from(response),
            response,
            authorization: "#{response['Z1']};#{response['Z4']};#{response['A1']};#{action}",
            avs_result: AVSResult.new(code: response['Z9']),
            cvv_result: CVVResult.new(response['Z14']),
            test: test?
        )
      end

      def p_sign(params)
        Digest::SHA1.hexdigest(@options[:merchant_key] + params.values.join(''))
      end

      def headers
        { 'Content-Type' => 'text/json' }
      end

      def url
        test? ? test_url : live_url
      end

      def success_from(response)
        result = response['results'][0]
        result['responsecode'] == 4 && result['reasoncode'] == 1
      end

      def message_from(response)
        response[:status] || 'Transaction has been approved successfully'
      end
    end
  end
end
