-- v0.47b Giacenze Shopify becomes Zia Fausta (was Zio Fausto) so it can take a female portrait (zia-05-bob-cardigan).
do $$
declare n int;
begin
  update fabula.bot_nicknames
     set nickname = 'Zia Fausta', avatar_url = 'avatars/shopify_inventory.png', updated_at = now()
   where agent = 'shopify_inventory' and nickname = 'Zio Fausto';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'v047b: shopify_inventory is not Zio Fausto any more'; end if;
end $$;
