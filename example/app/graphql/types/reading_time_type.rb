# The ReadingTime type is no model, so this class declares none: its object is the
# Hash Types::PostType#reading_time returns. `words` is read off it by the default
# reader; `minutes` is computed here, with the field's argument as a snake_case
# keyword (the SDL's default when the client leaves it out).
class Types::ReadingTimeType < Types::BaseObject
  def minutes(words_per_minute:)
    [(object[:words] / words_per_minute.to_f).ceil, 1].max
  end
end
