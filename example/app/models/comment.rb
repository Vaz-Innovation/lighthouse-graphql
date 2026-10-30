class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :author, class_name: 'User', inverse_of: :comments

  validates :body, presence: true

  # A stable order, so cursors keep pointing at the same comments between pages.
  scope :chronological, -> { order(:created_at, :id) }

  # Query.searchComments runs through it (@search, with Searchkick). Indexed in a
  # Solid Queue job after each change, and only while its post is published: a
  # search reads the index, not the database, so what must not be found must not
  # be indexed. Post reindexes its comments when it is published or unpublished.
  searchkick callbacks: :async

  # What the index holds: `body` to search, `post_id` for searchComments' @eq.
  def search_data = { body: body, post_id: post_id }

  def should_index? = post.published?

  # Reindexing reads each comment's post (should_index?): loaded with the comments, one query a batch.
  scope :search_import, -> { includes(:post) }

  # What a search may return, checked in the database as the comments it finds load
  # (Lighthouse's search_results): the index lags behind until the job has run, and
  # keeps a comment of an unpublished post for good if the job fails.
  scope :search_results, -> { where(post: Post.published) }
end
