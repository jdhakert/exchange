require 'rails_helper'
require 'support/use_stripe_mock'

describe Api::GraphqlController, type: :request do
  describe 'seller_counter_offer mutation' do
    include_context 'GraphQL Client'
    let(:partner_id) { jwt_partner_ids.first }
    let(:user_id) { jwt_user_id }
    let(:artwork_location) { { country: 'US' } }
    let(:artwork) { { _id: 'a-1', current_version_id: '1', location: artwork_location, domestic_shipping_fee_cents: 1000 } }
    let(:order_state) { Order::SUBMITTED }
    let!(:order) { Fabricate(:order, state: order_state, seller_id: partner_id, buyer_id: user_id, **shipping_info) }
    let!(:offer) { Fabricate(:offer, order: order, amount_cents: 10000) }
    let(:line_item_artwork_version) { artwork[:current_version_id] }
    let!(:line_item) { Fabricate(:line_item, order: order, list_price_cents: 2000_00, artwork_id: artwork[:_id], artwork_version_id: line_item_artwork_version, quantity: 2) }
    let(:partner_address) do
      Address.new(
        street_line1: '401 Broadway',
        country: 'US',
        city: 'New York',
        region: 'NY',
        postal_code: '10013'
      )
    end
    let(:shipping_info) do
      {
        shipping_name: 'Fname Lname',
        shipping_address_line1: '12 Vanak St',
        shipping_address_line2: 'P 80',
        shipping_city: 'New York',
        shipping_postal_code: '02198',
        buyer_phone_number: '00123456',
        shipping_region: 'NY',
        shipping_country: 'US',
        fulfillment_type: Order::SHIP
      }
    end
    let(:taxjar_client) { double }
    let(:tax_response) { double(amount_to_collect: 3.00) }

    let(:mutation) do
      <<-GRAPHQL
        mutation($input: SellerCounterOfferInput!) {
          sellerCounterOffer(input: $input) {
            orderOrError {
              ... on OrderWithMutationSuccess {
                order {
                  id
                  state
                }
              }
              ... on OrderWithMutationFailure {
                error {
                  code
                  data
                  type
                }
              }
            }
          }
        }
      GRAPHQL
    end

    let(:seller_counter_offer_input) do
      {
        input: {
          offerId: offer.id.to_s,
          amountCents: 10000
        }
      }
    end

    before do
      order.update!(last_offer: offer)

      allow(GravityService).to receive(:fetch_partner_locations).with(partner_id).and_return([partner_address])
      allow(GravityService).to receive(:get_artwork).and_return(artwork)
      allow(Taxjar::Client).to receive(:new).with(api_key: Rails.application.config_for(:taxjar)['taxjar_api_key'], api_url: nil).and_return(taxjar_client)
      allow(taxjar_client).to receive(:tax_for_order).with(any_args).and_return(tax_response)
    end

    context 'when not in the submitted state' do
      let(:order_state) { Order::PENDING }

      it "returns invalid state transition error and doesn't change the order state" do
        response = client.execute(mutation, seller_counter_offer_input)

        expect(response.data.seller_counter_offer.order_or_error.error.type).to eq 'validation'
        expect(response.data.seller_counter_offer.order_or_error.error.code).to eq 'invalid_state'
        expect(order.reload.state).to eq Order::PENDING
      end
    end

    context 'when attempting to counter not-the-last-offer' do
      it 'returns a validation error and does not change the order state' do
        create_order_and_original_offer
        create_another_offer

        response = client.execute(mutation, seller_counter_offer_input)

        expect(response.data.seller_counter_offer.order_or_error.error.type).to eq 'validation'
        expect(response.data.seller_counter_offer.order_or_error.error.code).to eq 'not_last_offer'
        expect(order.reload.state).to eq Order::SUBMITTED
      end
    end

    context 'with user without permission to this partner' do
      let(:partner_id) { 'another-partner-id' }

      it 'returns permission error' do
        response = client.execute(mutation, seller_counter_offer_input)

        expect(response.data.seller_counter_offer.order_or_error.error.type).to eq 'validation'
        expect(response.data.seller_counter_offer.order_or_error.error.code).to eq 'not_found'
        expect(order.reload.state).to eq Order::SUBMITTED
      end
    end

    context 'when the specified offer does not exist' do
      let(:seller_counter_offer_input) do
        {
          input: {
            offerId: '-1',
            amountCents: 20000
          }
        }
      end

      it 'returns a not-found error' do
        expect { client.execute(mutation, seller_counter_offer_input) }.to raise_error do |error|
          expect(error.status_code).to eq(404)
        end
      end
    end

    context 'with proper permission' do
      it 'counters the order' do
        expect do
          client.execute(mutation, seller_counter_offer_input)
          expect(order.reload.last_offer.responds_to).to eq(offer)
          expect(order.reload.last_offer.amount_cents).to eq(10000)
          expect(order.reload.last_offer.tax_total_cents).to eq(300)
          expect(order.reload.last_offer.should_remit_sales_tax).to eq(false)
          expect(order.reload.last_offer.amount_cents).to eq(10000)
          expect(order.reload.last_offer.submitted_at).not_to eq(nil)
          # for partner counte offer creator_id and from_id are different
          expect(order.reload.last_offer.creator_id).to eq(user_id)
          expect(order.reload.last_offer.from_id).to eq(partner_id)
          # shouldn't update order amounts until offer is accepted
          expect(order.reload.items_total_cents).to eq(0)
        end.to change { order.reload.offers.count }.from(1).to(2)
      end
    end
  end

  def create_order_and_original_offer
    order
    offer
  end

  def create_another_offer
    another_offer = Fabricate(:offer, order: order)
    order.update!(last_offer: another_offer)
  end
end
