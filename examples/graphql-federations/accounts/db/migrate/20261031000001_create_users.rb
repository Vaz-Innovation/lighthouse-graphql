class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false, index: { unique: true }
      t.string :role, null: false, default: 'member'
      t.string :api_token, index: { unique: true }
      # A stale count of the user's posts, from before the blog subgraph took User.postsCount over (@override).
      t.integer :posts_count, null: false, default: 0
      t.text :internal_notes
      t.timestamps
    end

    # What a user liked in the blog subgraph: a Post or a Comment (an Authored), by its UUID.
    create_table :likes do |t|
      t.references :user, null: false, foreign_key: true
      t.uuid :authored_id, null: false
      t.timestamps
      t.index %i[user_id authored_id], unique: true
    end
  end
end
