# pg_search's multisearch documents (rails g pg_search:migration:multisearch): one row for each
# record of a `multisearchable` model, which Query.everything searches together.
class CreatePgSearchDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :pg_search_documents do |t|
      t.text :content
      t.belongs_to :searchable, polymorphic: true, index: true
      t.timestamps null: false
    end
  end
end
