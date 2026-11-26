class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments, id: :uuid do |t|
      t.references :post, type: :uuid, null: false, foreign_key: true
      # A user of the accounts subgraph.
      t.bigint :author_id, null: false, index: true
      t.text :body, null: false
      t.timestamps
    end
  end
end
