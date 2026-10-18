class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments do |t|
      t.text :body, null: false
      t.references :post, type: :bigint, null: false, foreign_key: true
      t.references :author, type: :bigint, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end
  end
end
