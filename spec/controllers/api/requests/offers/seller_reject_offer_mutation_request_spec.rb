require 'rails_helper'
require 'support/use_stripe_mock'

describe Api::GraphqlController, type: :request do
  describe 'seller_reject_order mutation' do
    include_context 'GraphQL Client'
    let(:partner_id) { jwt_partner_ids.first }
    let(:user_id) { jwt_user_id }
    let(:order) { Fabricate(:order, state: order_state, seller_id: partner_id, buyer_id: user_id) }
    let(:offer) { Fabricate(:offer, order: order) }
    let(:order_state) { Order::SUBMITTED }
    let(:reject_reason) { 'SELLER_REJECTED_OFFER_TOO_LOW' }

    let(:mutation) do
      <<-GRAPHQL
        mutation($input: SellerRejectOfferInput!) {
          sellerRejectOffer(input: $input) {
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

    let(:seller_reject_offer_input) do
      {
        input: {
          offerId: offer.id.to_s,
          rejectReason: reject_reason
        }
      }
    end

    before do
      order.update!(last_offer: offer)
    end

    context 'when not in the submitted state' do
      let(:order_state) { Order::PENDING }

      it "returns invalid state transition error and doesn't change the order state" do
        response = client.execute(mutation, seller_reject_offer_input)

        expect(response.data.seller_reject_offer.order_or_error.error.type).to eq 'validation'
        expect(response.data.seller_reject_offer.order_or_error.error.code).to eq 'invalid_state'
        expect(order.reload.state).to eq Order::PENDING
      end
    end

    context 'when attempting to reject not the last offer' do
      it 'returns a validation error and does not change the order state' do
        create_order_and_original_offer
        create_another_offer

        response = client.execute(mutation, seller_reject_offer_input)

        expect(response.data.seller_reject_offer.order_or_error.error.type).to eq 'validation'
        expect(response.data.seller_reject_offer.order_or_error.error.code).to eq 'not_last_offer'
        expect(order.reload.state).to eq Order::SUBMITTED
      end
    end

    context 'with user without permission to this partner' do
      let(:partner_id) { 'another-partner-id' }

      it 'returns permission error' do
        response = client.execute(mutation, seller_reject_offer_input)

        expect(response.data.seller_reject_offer.order_or_error.error.type).to eq 'validation'
        expect(response.data.seller_reject_offer.order_or_error.error.code).to eq 'not_found'
        expect(order.reload.state).to eq Order::SUBMITTED
      end
    end

    context 'when the specified offer does not exist' do
      let(:seller_reject_offer_input) do
        {
          input: {
            offerId: '-1',
            rejectReason: reject_reason
          }
        }
      end

      it 'returns a not-found error' do
        expect { client.execute(mutation, seller_reject_offer_input) }.to raise_error do |error|
          expect(error.status_code).to eq(404)
        end
      end
    end

    context 'with proper permission' do
      it 'rejects the order' do
        expect do
          client.execute(mutation, seller_reject_offer_input)
        end.to change { order.reload.state }.from(Order::SUBMITTED).to(Order::CANCELED)
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
