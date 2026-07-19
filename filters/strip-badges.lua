-- Strip shields.io badges from the rendered docs site.
--
-- Badges are README furniture: they belong on the repo landing page, not in the
-- published documentation. They are also a build hazard here — sites rendered
-- with `embed-resources: true` fetch and inline every external image at render
-- time, so when shields.io rate-limits or 403s the runner, pandoc emits
--   [WARNING] Could not fetch resource https://img.shields.io/...
-- and the zero-warning gate in publish.yml fails the build. That failure has
-- nothing to do with the repo's content and recurs unpredictably.
--
-- Applying this during render (rather than asking each repo to mark up its
-- markdown) keeps README.md plain and portable: GitHub still renders badges
-- normally, with no wrapper divs or marker syntax leaking into the page.

local function is_badge(src)
  return src ~= nil and src:match("img%.shields%.io") ~= nil
end

-- Badges are usually an image wrapped in a link: [![alt][ref]](target).
-- Drop the whole link so no empty anchor is left behind.
function Link(el)
  if #el.content == 1
     and el.content[1].t == "Image"
     and is_badge(el.content[1].src) then
    return {}
  end
end

-- Bare (unlinked) badge images.
function Image(el)
  if is_badge(el.src) then
    return {}
  end
end

-- A badge row is typically its own paragraph; once emptied, drop it so the page
-- has no stray blank block where the badges used to be.
function Para(el)
  if #el.content == 0 then
    return {}
  end
end
