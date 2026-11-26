# Free-form JSON about a post (labels, series...), filtered by @whereJsonContains.
class AddMetadataToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :metadata, :json
  end
end
