class CommitOrderService
  attr_accessor :order

  COMMITTABLE_ACTIONS = %i[approve submit].freeze

  def initialize(order, action, user_id)
    @order = order
    @action = action
    @user_id = user_id
    @transaction = nil
    @deducted_inventory = []
  end

  def process!
    pre_process!
    commit_order!
    post_process!
    @order
  rescue Errors::ValidationError, Errors::ProcessingError => e
    undeduct_inventory
    raise e
  ensure
    handle_transaction
  end

  private

  def handle_transaction
    return if @transaction.blank?

    @order.transactions << @transaction
    notify_failed_charge if @transaction.failed?
  end

  def commit_order!
    @order.send("#{@action}!") do
      deduct_inventory
      process_payment
    end
  end

  def undeduct_inventory
    @deducted_inventory.each { |li| GravityService.undeduct_inventory(li) }
    @deducted_inventory = []
  end

  def deduct_inventory
    # Try holding artwork and deduct inventory
    @order.line_items.each do |li|
      GravityService.deduct_inventory(li)
      @deducted_inventory << li
    end
  end

  def process_payment
    raise NotImplementedError
  end

  def pre_process!
    raise Errors::ValidationError, :uncommittable_action unless COMMITTABLE_ACTIONS.include? @action
    raise Errors::ValidationError, :missing_required_info unless @order.can_commit?

    validate_artwork_versions!
    validate_credit_card!
    validate_commission_rate!

    OrderTotalUpdaterService.new(@order, partner[:effective_commission_rate]).update_totals!
  end

  def validate_commission_rate!
    raise Errors::ValidationError.new(:missing_commission_rate, partner_id: partner[:id]) if partner[:effective_commission_rate].blank?
  end

  def validate_artwork_versions!
    @order.line_items.each do |li|
      artwork = GravityService.get_artwork(li[:artwork_id])
      if artwork[:current_version_id] != li[:artwork_version_id]
        Exchange.dogstatsd.increment 'submit.artwork_version_mismatch'
        raise Errors::ProcessingError, :artwork_version_mismatch
      end
    end
  end

  def credit_card
    @credit_card ||= GravityService.get_credit_card(@order.credit_card_id)
  end

  def partner
    @partner ||= GravityService.fetch_partner(@order.seller_id)
  end

  def merchant_account
    @merchant_account ||= GravityService.get_merchant_account(@order.seller_id)
  end

  def post_process!
    @order.update!(external_charge_id: @transaction.external_id)
    Exchange.dogstatsd.increment "order.#{@action}"
  end

  def notify_failed_charge
    PostTransactionNotificationJob.perform_later(@transaction.id, TransactionEvent::CREATED, @user_id)
  end

  def construct_charge_params
    {
      credit_card: credit_card,
      buyer_amount: @order.buyer_total_cents,
      merchant_account: merchant_account,
      seller_amount: @order.seller_total_cents,
      currency_code: @order.currency_code,
      metadata: charge_metadata,
      description: charge_description
    }
  end

  def validate_credit_card!
    error_type = nil
    error_type = :credit_card_missing_external_id if credit_card[:external_id].blank?
    error_type = :credit_card_missing_customer if credit_card.dig(:customer_account, :external_id).blank?
    error_type = :credit_card_deactivated unless credit_card[:deactivated_at].nil?
    raise Errors::ValidationError.new(error_type, credit_card_id: credit_card[:id]) if error_type
  end

  def charge_description
    partner_name = (partner[:name] || '').parameterize[0...12].upcase
    "#{partner_name} via Artsy"
  end

  def charge_metadata
    {
      exchange_order_id: @order.id,
      buyer_id: @order.buyer_id,
      buyer_type: @order.buyer_type,
      seller_id: @order.seller_id,
      seller_type: @order.seller_type,
      type: @order.auction_seller? ? 'auction-bn' : 'bn-mo'
    }
  end
end
