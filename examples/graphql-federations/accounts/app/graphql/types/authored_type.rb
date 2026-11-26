# Authored, which the blog subgraph defines (an interface of Post and Comment)
# and accounts extends as an @interfaceObject. Accounts has no model for it:
# `_entities` resolves it to the router's representation, `{ "id" => ... }`,
# and these methods count the likes of that id, batched with the Dataloader.
class Types::AuthoredType < Types::BaseObject
  def likes_count
    dataloader.with(Sources::LikeCounts).load(object[:id])
  end

  def liked_by
    User.joins(:likes).where(likes: { authored_id: object[:id] }).order('likes.created_at')
  end
end
