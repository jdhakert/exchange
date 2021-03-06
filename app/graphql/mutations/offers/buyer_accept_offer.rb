class Mutations::Offers::BuyerAcceptOffer < Mutations::Offers::BaseAcceptOffer
  alias authorize! authorize_buyer_request!
  def waiting_for_accept?(offer)
    offer.from_participant != Order::BUYER
  end
end
