# Sample data to explore the API with: `bin/rails db:seed`, then see README.md.
ada = User.find_or_create_by!(email: 'ada@example.com') { |user| user.assign_attributes(name: 'Ada Lovelace', role: 'admin') }
grace = User.find_or_create_by!(email: 'grace@example.com') { |user| user.name = 'Grace Hopper' }

rails, graphql = %w[rails graphql].map { |name| Tag.find_or_create_by!(name: name) }

post = Post.find_or_create_by!(title: 'Notes on the Analytical Engine') do |record|
  record.assign_attributes(author: ada, body: 'The engine weaves algebraic patterns.', published: true, tags: [graphql])
end
Post.find_or_create_by!(title: 'Compilers for everyone') do |record|
  record.assign_attributes(author: grace, body: 'Programs should read like English.', published: true, tags: [rails, graphql])
end
Post.find_or_create_by!(title: 'A draft about nanoseconds') { |record| record.assign_attributes(author: grace, published: false) }
Comment.find_or_create_by!(post: post, author: grace, body: 'Brilliant.')

puts "Signed in as Ada (admin):  Authorization: Bearer #{ada.api_token}"
puts "Signed in as Grace:        Authorization: Bearer #{grace.api_token}"
