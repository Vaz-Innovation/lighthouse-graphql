# frozen_string_literal: true

require 'paranoia'
require 'discard'

# Soft-deletable models for the @softDeletes / @trashed / @restore / @forceDelete
# / @withoutGlobalScopes specs: one per strategy Support::SoftDeletes detects.
ActiveRecord::Schema.define do
  create_table :soft_projects, force: true do |t|
    t.string :name
  end

  # A plain `deleted_at` column, no gem.
  create_table :soft_tasks, force: true do |t|
    t.string :name
    t.integer :soft_project_id
    t.datetime :deleted_at
  end

  # paranoia
  create_table :paranoid_items, force: true do |t|
    t.string :name
    t.integer :soft_project_id
    t.datetime :deleted_at
  end

  # discard (backs two models: with and without a default scope)
  create_table :discard_items, force: true do |t|
    t.string :name
    t.datetime :discarded_at
  end

  # A default scope, and an app-defined `without_` scope for @withoutGlobalScopes.
  create_table :scheduled_posts, force: true do |t|
    t.string :title
    t.datetime :schedule_at
    t.boolean :archived, default: false
  end
end

class SoftProject < ApplicationRecord
  has_many :soft_tasks, dependent: :destroy
  has_many :paranoid_items, dependent: :destroy
end

class SoftTask < ApplicationRecord
  belongs_to :soft_project, optional: true

  scope :alpha, -> { where('name LIKE ?', 'a%') }
end

# Refuses to be destroyed, so @forceDelete reports it.
class ProtectedTask < ApplicationRecord
  self.table_name = 'soft_tasks'
  before_destroy { throw :abort }
end

# The same column, with a default scope hiding the trashed (a hand-rolled paranoia).
class HiddenTask < ApplicationRecord
  self.table_name = 'soft_tasks'
  default_scope { where(deleted_at: nil) }
end

class ParanoidItem < ApplicationRecord
  acts_as_paranoid
  belongs_to :soft_project, optional: true
end

class DiscardItem < ApplicationRecord
  include Discard::Model
end

class DiscardKeptItem < ApplicationRecord
  self.table_name = 'discard_items'
  include Discard::Model

  default_scope -> { kept }
end

class ScheduledPost < ApplicationRecord
  default_scope { where.not(schedule_at: nil) }

  scope :without_scheduled, -> { unscope(where: :schedule_at) }
  scope :without_archived, -> { unscope(where: :schedule_at).where(archived: true) }
end
