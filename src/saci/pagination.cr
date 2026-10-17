module Saci
  # Kaminari/pagy-like pagination over `Saci::Record::Query`.
  #
  # ```
  # page = Saci::Pagination.paginate(
  #   Post.where(published: true).order(created_at: :desc),
  #   page: params.int("page", 1) || 1, # non-numeric query values fall back
  #   per_page: 25                      # to the default via `params.int`
  # )
  # page.records      # => Array(Post) for the current page
  # page.total_count  # => Int64 across all pages
  # render html: Saci::Pagination.paginate_nav(page, "/posts")
  # ```
  #
  # `paginate` accepts `Int` only — non-numeric input is the caller's job
  # (`params.int("page", 1) || 1` returns the fallback for missing or
  # non-numeric values). Out-of-range pages clamp to the last page;
  # `per_page` clamps to `1..MAX_PER_PAGE` (values below 1 fall back to
  # `DEFAULT_PER_PAGE`).
  #
  # Exactly two queries run per call: one `COUNT(*)` (filters/joins apply,
  # `ORDER`/`LIMIT`/`OFFSET` do not — same as `Query#count`) and one page
  # fetch. Filters and ordering on the given query are preserved.
  module Pagination
    MAX_PER_PAGE     = 100
    DEFAULT_PER_PAGE = 25

    class Page(T)
      getter records : Array(T)
      getter total_count : Int64
      getter total_pages : Int32
      getter current_page : Int32
      getter per_page : Int32
      getter next_page : Int32?
      getter prev_page : Int32?

      def initialize(
        @records : Array(T),
        @total_count : Int64,
        @total_pages : Int32,
        @current_page : Int32,
        @per_page : Int32,
        @next_page : Int32?,
        @prev_page : Int32?,
      )
      end
    end

    def self.paginate(query : Record::Query(T), page : Int = 1, per_page : Int = 25) : Page(T) forall T
      pp = sanitize_per_page(per_page)
      total = query.count
      total_pages = total <= 0 ? 0_i32 : ((total + pp - 1) // pp).to_i32
      current = sanitize_page(page, total_pages)
      records = query.limit(pp).offset((current - 1) * pp).to_a
      next_page = current < total_pages ? (current + 1) : nil
      prev_page = total_pages > 0 && current > 1 ? (current - 1) : nil
      Page(T).new(records, total, total_pages, current, pp, next_page, prev_page)
    end

    # Windowed page navigation (`/base`, `/base/page/N`, ...), mirroring
    # `Saci::Views.page_numbers` semantics: first/last plus a `window`
    # around the current page, `…` gaps, `rel="prev"`/`rel="next"` links,
    # and the current page marked with `aria-current="page"`.
    # `base_path` honors `:page` / `%{page}` placeholders and `?`-style
    # query strings, exactly like `page_numbers`. Returns `""` when there
    # is one page or less (empty result sets render nothing).
    def self.paginate_nav(page : Page(T), base_path : String, window : Int32 = 2) : String forall T
      total = page.total_pages
      return "" if total <= 1
      current = page.current_page.clamp(1, total)
      pages = [] of Int32?
      (1..total).each do |p|
        if p == 1 || p == total || (p - current).abs <= window
          pages << p
        elsif pages.last != nil
          pages << nil
        end
      end
      String.build do |io|
        io << %(<nav class="pagination">)
        if current > 1
          io << %(<a href="#{HTML.escape(nav_url(base_path, current - 1))}" rel="prev">« Prev</a>)
        end
        pages.each do |p|
          if p.nil?
            io << %(<span class="gap">…</span>)
          elsif p == current
            io << %(<span class="current" aria-current="page">#{p}</span>)
          else
            io << %(<a href="#{HTML.escape(nav_url(base_path, p))}">#{p}</a>)
          end
        end
        if current < total
          io << %(<a href="#{HTML.escape(nav_url(base_path, current + 1))}" rel="next">Next »</a>)
        end
        io << "</nav>"
      end
    end

    private def self.sanitize_per_page(per_page : Int) : Int32
      return DEFAULT_PER_PAGE if per_page < 1
      return MAX_PER_PAGE if per_page > MAX_PER_PAGE
      per_page.to_i32
    end

    private def self.sanitize_page(page : Int, total_pages : Int32) : Int32
      return 1_i32 if total_pages <= 0
      return 1_i32 if page < 1
      return total_pages if page > total_pages
      page.to_i32
    end

    # Same URL conventions as `Saci::Views.page_numbers`: `:page` /
    # `%{page}` placeholders, `?page=N` when a query string is present,
    # otherwise `base` for page 1 and `base/page/N` for the rest.
    private def self.nav_url(base : String, page : Int32) : String
      if base.includes?(":page")
        base.sub(":page", page.to_s)
      elsif base.includes?("%{page}")
        base.gsub("%{page}", page.to_s)
      elsif base.includes?("?")
        "#{base}&page=#{page}"
      elsif page == 1
        base
      else
        stripped = base.ends_with?("/") ? base[0...-1] : base
        "#{stripped}/page/#{page}"
      end
    end
  end
end
