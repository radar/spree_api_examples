require_relative '../base'
require 'braintree'
require 'yaml'

module Examples
  module Checkout
    class WalkthroughWithExistingCreditCard
      def self.run(client)
        braintree_config_file = File.dirname(__FILE__) + "/braintree.yml"
        unless File.exists?(braintree_config_file)
          client.pending "braintree.yml does not exist. Cannot proceed."
          exit
        end

        # Create the order step by step:
        # You may also choose to start it off with some line items
        # See checkout/creating_with_line_items.rb
        response = client.post('/api/orders')

        if response.status == 201
          client.succeeded "Created new checkout."
          order = JSON.parse(response.body)
          if order['email'] == 'spree@example.com'
            # Email addresses are necessary for orders to transition to address.
            # This just makes really sure that the email is already set.
            # You will not have to do this in your own API unless you've customized it.
            client.succeeded 'Email set automatically on order successfully.'
          else
            client.failed %Q{
        Email address was not automatically set on order.'
          -> This may lead to problems transitioning to the address step.
            }
          end
        else
          client.failed 'Failed to create a new blank checkout.'
        end

        # Assign a line item to the order we just created.

        response = client.post("/api/orders/#{order['number']}/line_items",
          {
            line_item: {
              variant_id: 1,
              quantity: 1
            }
          }
        )


        if response.status == 201
          client.succeeded "Added a line item."
        else
          client.failed "Failed to add a line item."
        end

        # Transition the order to the 'address' state
        response = client.put("/api/checkouts/#{order['number']}/next")
        if response.status == 200
          order = JSON.parse(response.body)
          client.succeeded "Transitioned order into address state."
        else
          client.failed "Could not transition order to address state."
        end

        # Add address information to the order
        # Before you make this request, you may need to make a request to one or both of:
        # - /api/countries
        # - /api/states
        # This will give you the correct country_id and state_id params to use for address information.

        # First, get the country:
        response = client.get('/api/countries?q[name_cont]=United States')
        if response.status == 200
          client.succeeded "Retrieved a list of countries."
          countries = JSON.parse(response.body)['countries']
          usa = countries.first
          if usa['name'] != 'United States'
            client.failed "Expected first country to be 'United States', but it wasn't."
          end
        else
          client.failed "Failed to retrieve a list of countries."
        end

        # Then, get the state we want from the states of that country:

        response = client.get("/api/countries/#{usa['id']}/states?q[name_cont]=Maryland")
        if response.status == 200
          client.succeeded "Retrieved a list of states."
          states = JSON.parse(response.body)['states']
          maryland = states.first
          if maryland['name'] != 'Maryland'
            client.failed "Expected first state to be 'Maryland', but it wasn't."
          end
        else
          client.failed "Failed to retrieve a list of states."
        end

        # We can finally submit some address information now that we have it all:

        address = {
          first_name: 'Test',
          last_name: 'User',
          address1: 'Unit 1',
          address2: '1 Test Lane',
          country_id: usa['id'],
          state_id: maryland['id'],
          city: 'Bethesda',
          zipcode: '20814',
          phone: '(555) 555-5555'
        }

        response = client.put("/api/checkouts/#{order['number']}",
          {
            order: {
              bill_address_attributes: address,
              ship_address_attributes: address
            }
          }
        )

        if response.status == 200
          client.succeeded "Address details added."
          order = JSON.parse(response.body)
          if order['state'] == 'delivery'
            client.succeeded "Order automatically transitioned to 'delivery'."
          else
            client.failed "Order failed to automatically transition to 'delivery'."
          end
        else
          client.failed "Could not add address details to order."
        end

        # Next step: delivery!

        first_shipment = order['shipments'].first
        response = client.put("/api/checkouts/#{order['number']}",
          {
            order: {
              shipments_attributes: [
                id: first_shipment['id'],
                selected_shipping_rate_id: first_shipment['shipping_rates'].first['id']
              ]
            }
          }
        )

        if response.status == 200
          client.succeeded "Delivery options selected."
          order = JSON.parse(response.body)
          if order['state'] == 'payment'
            client.succeeded "Order automatically transitioned to 'payment'."
          else
            client.failed "Order failed to automatically transition to 'payment'."
          end
        else
          client.failed "The store was not happy with the selected delivery options."
        end

        # Next step: payment!

        braintree_config = YAML.load_file(braintree_config_file)

        Braintree::Configuration.environment = braintree_config["environment"].to_sym
        Braintree::Configuration.merchant_id = braintree_config["merchant_id"]
        Braintree::Configuration.public_key = braintree_config["public_key"]
        Braintree::Configuration.private_key = braintree_config["private_key"]

        result = Braintree::Customer.create(
          :first_name => "Test",
          :last_name => "User",
          :credit_card => {
            :number => "4111111111111111",
            :expiration_date => "05/2020"
          }
        )

		customer_id = result.customer.id
		# Base second token off first, so we can easily tell which one got processed
        card_token = result.customer.credit_cards[0].token + "_second"

        result = Braintree::CreditCard.create(
		  :customer_id => customer_id,
		  :token => card_token,
		  :number => "4111111111111111",
		  :expiration_date => "05/2020"
        )

        # Find the braintree payment method:
        braintree_payment_method = order['payment_methods'].detect { |pm| pm['name'] == "Braintree" }
        if braintree_payment_method
          response = client.put("/api/checkouts/#{order['number']}",
          {
            order: {
              payments_attributes: [{
                payment_method_id: braintree_payment_method['id']
              }],
            },
            payment_source: {
              braintree_payment_method['id'] => {
                gateway_customer_profile_id: customer_id,
                gateway_payment_profile_id: card_token,
              }
            }
          })

          if response.status == 200
            order = JSON.parse(response.body)
            client.succeeded "Payment details provided for the order."
            # Order will transition to the confirm state only if the selected payment
            # method allows for payment profiles.
            # The dummy Credit Card gateway in Spree does, so confirm is shown for this order.
            if order['state'] == 'confirm'
              client.succeeded "Order automatically transitioned to 'confirm'."
            else
              client.failed "Order did not transition automatically to 'confirm'."
            end
          else
            client.failed "Payment details were not accepted for the order."
          end
        else
          client.failed "Braintree payment method not found."
        end

        # This is the final point where the user gets to view their order's final information.
        # All that's required at this point is that we complete the order, which is as easy as:

        response = client.put("/api/checkouts/#{order['number']}/next")
        if response.status == 200
          order = JSON.parse(response.body)
          if order['state'] == 'complete'
            client.succeeded "Order complete!"
          else
            client.failed "Order did not complete."
          end
        else
          client.failed "Order could not transition to 'complete'."
        end
      end
    end
  end
end

Examples.run(Examples::Checkout::WalkthroughWithExistingCreditCard)