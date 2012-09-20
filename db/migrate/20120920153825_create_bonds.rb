class CreateBonds < ActiveRecord::Migration
  def self.up
    create_table :bonds do |t|
      t.integer :creditor_id
      t.integer :debtor_id
      t.integer :qty
      t.integer :goal_id

      t.timestamps
    end
  end

  def self.down
    drop_table :bonds
  end
end
