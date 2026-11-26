class CreateTags < ActiveRecord::Migration[8.1]
  def change
    create_table :tags do |t|
      t.string :name, null: false, index: { unique: true }
      t.timestamps
    end

    create_table :taggings do |t|
      t.references :post, type: :uuid, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.timestamps
    end
  end
end
