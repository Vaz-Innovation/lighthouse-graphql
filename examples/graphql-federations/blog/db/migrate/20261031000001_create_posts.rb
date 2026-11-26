class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    enable_extension 'pgcrypto'

    # Posts and comments are entities of one interface, Authored, whose key (id)
    # must tell them apart: UUIDs, unique across both tables.
    create_table :posts, id: :uuid do |t|
      t.string :title, null: false
      t.text :body
      t.boolean :published, null: false, default: false
      # A user of the accounts subgraph.
      t.bigint :author_id, null: false, index: true
      t.timestamps
    end
  end
end
