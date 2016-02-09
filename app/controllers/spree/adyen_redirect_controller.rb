module Spree
  class AdyenRedirectController < StoreController
    before_filter :check_signature, :only => :confirm

    skip_before_filter :verify_authenticity_token

    def confirm
      payment_number = extract_payment_number_from_merchant_reference(params[:merchantReference])
      @payment = Spree::Payment.find_by_number(payment_number)
      @payment.response_code = params[:pspReference]
      @payment_order = @payment.order

      if authorized?
        @payment.pend
        @payment.save
      elsif pending?
        # Leave in payment in processing state and wait for update from Notification
        @payment.save
      else
        @payment.failure
        @payment.save

        flash.notice = Spree.t('payment_messages.processing_failed')
        redirect_to checkout_state_path(@payment_order.state) and return
      end

      @payment_order.next

      redirect_to redirect_path and return
    end


    def authorise3d
      if params[:MD].present? && params[:PaRes].present? && params[:payment_number].present?
        crypt           = ActiveSupport::MessageEncryptor
                            .new(Rails.application.secrets.secret_key_base)
        payment_num     = crypt.decrypt_and_verify(params[:payment_number])
        @payment        = Spree::Payment.find_by(number: payment_num)
        @payment_order  = @payment.order
        gateway         = @payment.payment_method
        md              = params[:MD]
        pa_response     = params[:PaRes]

        response3d = gateway.authorise3d(md, pa_response, request.ip, request.headers.env)
        @payment.response_code = response3d.psp_reference

        if response3d.success?
          @payment.pend
          @payment.save
          @payment_order.next
        else
          @payment.failure
          @payment.save
          flash.notice = Spree.t('payment_messages.processing_failed')
        end

      end

      if @payment_order
        # Update iframe and redirect parent to checkout state
        render partial: 'spree/shared/reload_parent', locals: { new_url: redirect_path }
      else
        render_404
      end
    end

    private

      def pending?
        params[:authResult] == 'PENDING'
      end

      def extract_payment_number_from_merchant_reference(merchant_reference)
        merchant_reference.split('-').last
      end

      def authorized?
        params[:authResult] == "AUTHORISED"
      end

      def redirect_path
        if @payment_order.completed?
          cookies[:completed_order] = @payment_order.id
          @current_order = @payment_order = nil
          flash.notice = Spree.t(:order_processed_successfully)
          completion_route
        else
          checkout_state_path(@payment_order.state)
        end
      end

      def completion_route
        spree.checkout_complete_path
      end

      def check_signature
        unless ::Adyen::Form.redirect_signature_check(params, payment_method.shared_secret)
          raise "Payment Method not found."
        end
      end

      # TODO find a way to send the payment method id to Adyen servers and get
      # it back here to make sure we find the right payment method
      def payment_method
        @payment_method ||= Spree::PaymentMethod.available(:both, current_store).find do |m|
                            m.is_a?(Spree::Gateway::AdyenHPP)
                          end
      end

  end
end
