require 'spec_helper'

module Spree
  module Stock
    describe Estimator do
      let!(:shipping_method) { create(:shipping_method) }
      let(:package) { build(:stock_package_fulfilled) }
      let(:order) { package.order }

      subject { Estimator.new(order) }

      context "#shipping rates" do
        before(:each) do
          shipping_method.zones.first.members.create(:zoneable => order.ship_address.country)
          ShippingMethod.any_instance.stub_chain(:calculator, :available?).and_return(true)
          ShippingMethod.any_instance.stub_chain(:calculator, :compute).and_return(4.00)
          ShippingMethod.any_instance.stub_chain(:calculator, :preferences).and_return({:currency => "USD"})
          ShippingMethod.any_instance.stub_chain(:calculator, :marked_for_destruction?)

          package.stub(:shipping_methods => [shipping_method])
        end

        it "returns shipping rates from a shipping method if the order's ship address is in the same zone" do
          shipping_rates = subject.shipping_rates(package)
          shipping_rates.first.cost.should eq 4.00
        end

        it "does not return shipping rates from a shipping method if the order's ship address is in a different zone" do
          shipping_method.zones.each{|z| z.members.delete_all}
          shipping_rates = subject.shipping_rates(package)
          shipping_rates.should == []
        end

        it "does not return shipping rates from a shipping method if the calculator is not available for that order" do
          ShippingMethod.any_instance.stub_chain(:calculator, :available?).and_return(false)
          shipping_rates = subject.shipping_rates(package)
          shipping_rates.should == []
        end

        it "returns shipping rates from a shipping method if the currency matches the order's currency" do
          shipping_rates = subject.shipping_rates(package)
          shipping_rates.first.cost.should eq 4.00
        end

        it "does not return shipping rates from a shipping method if the currency is different than the order's currency" do
          order.currency = "GBP"
          shipping_rates = subject.shipping_rates(package)
          shipping_rates.should == []
        end

        it "does not return shipping rates if the shipping method's calculator raises an exception" do
          ShippingMethod.any_instance.stub_chain(:calculator, :available?).and_raise(Exception, "Something went wrong!")
          subject.should_receive(:log_calculator_exception)
          lambda { subject.shipping_rates(package) }.should_not raise_error
        end

        it "sorts shipping rates by cost" do
          shipping_methods = 3.times.map { create(:shipping_method) }
          shipping_methods[0].stub_chain(:calculator, :compute).and_return(5.00)
          shipping_methods[1].stub_chain(:calculator, :compute).and_return(3.00)
          shipping_methods[2].stub_chain(:calculator, :compute).and_return(4.00)

          subject.stub(:shipping_methods).and_return(shipping_methods)

          expect(subject.shipping_rates(package).map(&:cost)).to eq %w[3.00 4.00 5.00].map(&BigDecimal.method(:new))
        end

        context "general shipping methods" do
          let(:shipping_methods) { 2.times.map { create(:shipping_method) } }

          it "selects the most affordable shipping rate" do
            shipping_methods[0].stub_chain(:calculator, :compute).and_return(5.00)
            shipping_methods[1].stub_chain(:calculator, :compute).and_return(3.00)

            subject.stub(:shipping_methods).and_return(shipping_methods)

            expect(subject.shipping_rates(package).sort_by(&:cost).map(&:selected)).to eq [true, false]
          end

          it "selects the most affordable shipping rate and doesn't raise exception over nil cost" do
            shipping_methods[0].stub_chain(:calculator, :compute).and_return(1.00)
            shipping_methods[1].stub_chain(:calculator, :compute).and_return(nil)

            subject.stub(:shipping_methods).and_return(shipping_methods)

            subject.shipping_rates(package)
          end
        end

        context "involves backend only shipping methods" do
          let(:backend_method) { create(:shipping_method, display_on: "back_end") }
          let(:generic_method) { create(:shipping_method) }

          before do
            backend_method.stub_chain(:calculator, :compute).and_return(0.00)
            generic_method.stub_chain(:calculator, :compute).and_return(5.00)
            subject.stub(:shipping_methods).and_return([backend_method, generic_method])
          end

          it "does not return backend rates at all" do
            expect(subject.shipping_rates(package).map(&:shipping_method_id)).to eq([generic_method.id])
          end

          # regression for #3287
          it "doesn't select backend rates even if they're more affordable" do
            expect(subject.shipping_rates(package).map(&:selected)).to eq [true]
          end
        end

        context "includes tax adjustments if applicable" do
          let!(:tax_rate) { create(:tax_rate, zone: order.tax_zone) }

          before do
            Spree::ShippingMethod.all.each do |sm|
              sm.tax_category_id = tax_rate.tax_category_id
              sm.save
            end
            package.shipping_methods.map(&:reload)
          end


          it "links the shipping rate and the tax rate" do
            shipping_rates = subject.shipping_rates(package)
            expect(shipping_rates.first.tax_rate).to eq(tax_rate)
          end
        end
      end
    end
  end
end
