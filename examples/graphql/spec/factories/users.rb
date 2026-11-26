FactoryBot.define do
  factory :user do
    sequence(:name) { |n| "User #{n}" }
    sequence(:email) { |n| "user#{n}@example.com" }

    trait :admin do
      role { 'admin' }
    end
  end
end
