# The models of the accounts subgraph's database, which the blog only reads
# (config/database.yml): Rails' multiple databases.
class AccountsRecord < ApplicationRecord
  self.abstract_class = true

  connects_to database: { writing: :accounts, reading: :accounts }

  def readonly? = true
end
