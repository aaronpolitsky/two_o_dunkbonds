class Account < ApplicationRecord
  # A bond is just a link between two accounts establishing a payment flow
  # A swap is the same link seen from the other perspective.  

  belongs_to :user
  belongs_to :goal
  has_many :orders, :through => :user
  has_many :bonds, :foreign_key => :creditor_id # a creditor owns bonds and collects payments from debtors
  has_many :swaps, :class_name => "Bond", :foreign_key => :debtor_id # a debtor pays a creditor periodically, also the same as a swap
  has_many :line_items
  has_many :buys, :through => :line_items
  has_many :sells, :through => :line_items  
  has_many :cancellations, :through => :line_items
  has_many :payments, :foreign_key => :payer_id
  has_many :receipts, :class_name => "Payment", :foreign_key => :recipient_id

  before_destroy :empty_account?, prepend: true

  def credit!(amt)
    self.reload
    self.balance += amt
    self.save!
  end

  def debit!(amt)
    self.reload
    self.balance -= amt
    self.save!
  end

  def bond_qty
    return 0 if self.bonds.count.zero?
    self.bonds.sum(:qty)
  end

  def swap_qty
    return 0 if self.swaps.count.zero?
    self.swaps.sum(:qty)
  end

  def transfer_funds_to!(amount, recipient)
    self.debit! amount
    recipient.credit! amount
  end

  def is_bondholder?
    self.bond_qty > 0 || 
    self.swap_qty > 0 || 
    self.line_items.where(:type_of => "bond ask", :status => "pending").count > 0 || 
    self.line_items.where(:type_of => "swap bid", :status => "pending").count > 0 
  end
  
  def transfer_swap_to!(buyer)
    if self.is_treasury?
      buyer_swap = Bond.find_or_create_by(creditor_id: buyer.id, debtor_id: buyer.id)
      buyer_swap.qty += 1
      buyer_swap.save!
    else  #do we need an else?  treasury may be the only one who can do this. 
      # if self.swaps.count > 0
      #   # if self.swaps.exists?(:creditor_id => buyer.id)
      #   #   debugger
      #   #   bondswap = self.swaps.find_by_creditor_id(buyer.id)
      #   #   if bondswap.qty == 1
      #   #     bondswap.destroy
      #   #   else 
      #   #   #   bondswap.qty -= 1
      #   #   #   bondswap.save!
      #   #   end
      #   # else  
      #   seller_swap = self.swaps.first
      #   buyer_swap = buyer.swaps.find_or_create_by_creditor_id(seller_swap.creditor_id)
      #   buyer_swap.qty += 1
      #   buyer_swap.save!
      #   if (seller_swap.qty > 1)
      #     seller_swap.qty -= 1
      #     seller_swap.save!
      #   else #if qty == 1
      #     seller_swap.destroy
      #   end
      #   # end
      # end
    end
  end

  def transfer_bond_to!(buyer)
    if self.is_treasury?
      #find or create unique bond and increment
      buyer_bond = Bond.find_or_create_by(creditor_id: buyer.id, debtor_id: self.id)
      buyer_bond.qty += 1 
      buyer_bond.save!
    else #regular accounts, secondary market
    #these sell their bond end of the bond-swap relationship, if they have any to sell
      if (self.bonds.sum(:qty) > 0)
        bond = self.bonds.first #any will do
        buyer_bond = buyer.bonds.find_or_create_by(debtor_id: bond.debtor_id)            
        buyer_bond.qty += 1            
        buyer_bond.save!

        bond.qty -= 1
        bond.save!
        bond.destroy if bond.qty.zero?
      end
    end
  end

  def supporting?
    (self.bond_qty || self.swap_qty || self.line_items.where(:status => "pending", :type_of => "bond ask").sum(:qty)) > 0      
  end

  ######################
  #controller view stuff
  def bond_value
    self.goal.bond_face_value * self.bond_qty
  end

  def swap_cost
    self.line_items.where(:type_of => "swap bid", :status => "executed").sum(:qty) * self.goal.bond_face_value
  end

  def bond_value_on_block
    bond_ask_qty = self.line_items.where(:type_of => "bond ask",
                                         :status => "pending").sum(:qty)
    self.goal.bond_face_value * bond_ask_qty
  end

  def pledged
    bond_value + swap_cost + bond_value_on_block
  end

  def current_investment
    self.balance + 
    self.line_items.where(:type_of => "bond bid",
                          :status => "pending").inject(0){|sum, li| sum += (li.qty * li.max_bid_min_ask)} +
    self.line_items.where(:type_of => "swap bid",
                          :status => "pending").inject(0){|sum, li| sum += (li.qty * li.max_bid_min_ask)} 
  end

  def pending_investment
    self.balance - self.current_investment
  end

  def pending_qty

  end

  def pending_qty(type = nil)
    return self.line_items.where(:status => "pending").sum(:qty) if type.nil?
    self.line_items.where(:status => "pending", :type_of => type).sum(:qty)
  end

  def pledge_if_goal_succeeds
    # if bonds don't pay out
    self.balance
  end

  def pledge_if_goal_fails
    # if bonds do pay out:
    #   your balance, plus bond payouts, less swap payouts
    self.balance + bond_value - swap_cost
  end

  def feel
    held_swaps = self.line_items.where(:type_of => "swap bid", 
                                         :status => "executed").sum(:qty)
    held_bonds = self.line_items.where(:type_of => "bond bid",
                                         :status => "executed").sum(:qty) 
    if held_swaps > held_bonds
      "Optimistic"
    elsif held_swaps == held_bonds
      "Neutral"
    else
      "Pessimistic"
    end
  end
  
  def position
    pos = bond_qty - swap_qty 
    if (pos > 0)
      "#{pos} pessimistic"
    elsif 0
      "neutral"
    else
      "#{pos} optimistic"
    end
  end

  def histories
    histories = []
    # get placed line_items from orders
    self.orders.each do |o|
      o.line_items.each do |li|
        item = {
          :description     => "Placed" + li.type_of.capitalize,
          :date            => o.updated_at,
          :price           => li.max_bid_min_ask,
          :qty             => li.qty          
        }
        histories.push item
      end
    end

    # get cancelled line_items from cancellations
    self.cancellations.each do |c|
      item = {
        :description     => "Cancelled" + c.li.type_of.capitalize,
        :date            => c.created_at,
        :qty             => li.qty,
      }
      histories.push item
    end

    # get executed line_items from buys and sells
    self.buys.each do |b|
      item = {
        :description     => b.li.type_of.first.capitalize + "Buy",
        :date            => b.created_at,
        :price           => b.price,
        :qty             => b.qty,
        :subtotal        => b.price * b.qty
      }
      histories.push item
    end
    
    self.sells.each do |s|
      item = {
        :description     => s.li.type_of.first.capitalize + "Sale",
        :date            => s.created_at,
        :price           => -s.price,
        :qty             => s.qty,
        :subtotal        => s.price * s.qty
      }
      histories.push item
    end

    # get payments and receipts
    self.payments.each do |p|
      item = {
        :description     => "Swap Payout",
        :date            => p.created_at,
        :subtotal        => p.amount
      }
      histories.push item
    end

    self.receipts.each do |r|
      item = {
        :description     => "Bond Payout",
        :date            => r.created_at,
        :subtotal        => -r.amount
      }
      histories.push item
    end
    
    # sort by date
    histories.sort! {|a, b| a[:date] <=> b[:date]}

    if histories.empty?
      return histories
    end


  end

  private
  
  def empty_account?
    errors.add(:base, "This account cannot be closed because it has bonds.") unless self.bonds.empty?
    errors.add(:base, "This account cannot be closed because it has swaps.") unless self.swaps.empty?
    errors.add(:base, "This account cannot be closed because it has pending orders.") unless self.line_items.where(:status => "pending").empty?
    errors.blank?
  end


end

