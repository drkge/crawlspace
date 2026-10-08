import GRDB

enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE meta (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT
            );

            -- One wide row per URL: discovery, response and page fields. A single table keeps the
            -- 1M-row grid free of joins; unused columns are NULL and cost almost nothing in SQLite.
            CREATE TABLE urls (
                id INTEGER PRIMARY KEY,
                url TEXT NOT NULL,
                host TEXT NOT NULL,
                is_internal INTEGER NOT NULL,
                depth INTEGER NOT NULL,
                state INTEGER NOT NULL,
                found_via INTEGER NOT NULL,
                resource_type INTEGER NOT NULL,
                skip_reason TEXT,

                status_code INTEGER,
                status_text TEXT,
                error TEXT,
                blocked_by_robots INTEGER NOT NULL DEFAULT 0,
                content_type TEXT,
                size_bytes INTEGER,
                response_ms REAL,
                ttfb_ms REAL,
                redirect_url TEXT,
                redirect_to_id INTEGER,
                headers TEXT,
                crawled_at REAL,
                indexability INTEGER NOT NULL DEFAULT 0,
                indexability_reason TEXT,

                title TEXT,
                title_length INTEGER,
                title_pixels REAL,
                title_count INTEGER,
                meta_description TEXT,
                meta_description_length INTEGER,
                meta_description_pixels REAL,
                meta_description_count INTEGER,
                h1 TEXT,
                h1_length INTEGER,
                h1_count INTEGER,
                h1_second TEXT,
                h2 TEXT,
                h2_count INTEGER,
                canonical TEXT,
                canonical_id INTEGER,
                canonical_count INTEGER,
                meta_robots TEXT,
                x_robots_tag TEXT,
                lang TEXT,
                word_count INTEGER,
                content_hash INTEGER,
                outlinks INTEGER,
                external_outlinks INTEGER,
                hreflang_count INTEGER,
                structured_data_count INTEGER,

                inlinks INTEGER NOT NULL DEFAULT 0,
                unique_inlinks INTEGER NOT NULL DEFAULT 0
            );
            CREATE UNIQUE INDEX urls_on_url ON urls(url);
            CREATE INDEX urls_on_state ON urls(state, id);
            CREATE INDEX urls_on_kind ON urls(is_internal, resource_type);
            CREATE INDEX urls_on_status ON urls(status_code);

            CREATE TABLE links (
                source_id INTEGER NOT NULL,
                target_id INTEGER NOT NULL,
                type INTEGER NOT NULL,
                flags INTEGER NOT NULL,
                text TEXT NOT NULL DEFAULT '',
                PRIMARY KEY (source_id, target_id, type, text)
            ) WITHOUT ROWID;
            CREATE INDEX links_on_target ON links(target_id);

            CREATE TABLE hreflang (
                source_id INTEGER NOT NULL,
                lang TEXT NOT NULL,
                target_id INTEGER NOT NULL,
                PRIMARY KEY (source_id, lang, target_id)
            ) WITHOUT ROWID;
            CREATE INDEX hreflang_on_target ON hreflang(target_id);

            CREATE TABLE structured_data (
                url_id INTEGER NOT NULL,
                idx INTEGER NOT NULL,
                types TEXT NOT NULL,
                error TEXT,
                PRIMARY KEY (url_id, idx)
            ) WITHOUT ROWID;

            CREATE TABLE issues (
                code TEXT NOT NULL,
                url_id INTEGER NOT NULL,
                PRIMARY KEY (code, url_id)
            ) WITHOUT ROWID;
            CREATE INDEX issues_on_url ON issues(url_id);

            CREATE TABLE redirect_chains (
                start_id INTEGER PRIMARY KEY,
                hops INTEGER NOT NULL,
                final_id INTEGER,
                final_status INTEGER,
                is_loop INTEGER NOT NULL,
                path TEXT NOT NULL
            );

            CREATE TABLE bodies (
                url_id INTEGER PRIMARY KEY,
                html BLOB NOT NULL
            );
            """)
        }

        // JavaScript rendering and XML sitemaps.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
            ALTER TABLE urls ADD COLUMN js_rendered INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE urls ADD COLUMN raw_word_count INTEGER;
            ALTER TABLE urls ADD COLUMN raw_link_count INTEGER;
            ALTER TABLE urls ADD COLUMN rendered_link_count INTEGER;
            ALTER TABLE urls ADD COLUMN render_ms REAL;
            ALTER TABLE urls ADD COLUMN in_sitemap INTEGER NOT NULL DEFAULT 0;

            CREATE TABLE sitemaps (
                url TEXT PRIMARY KEY NOT NULL,
                kind TEXT,
                entry_count INTEGER NOT NULL DEFAULT 0,
                status_code INTEGER,
                error TEXT
            );

            CREATE TABLE sitemap_urls (
                url TEXT PRIMARY KEY NOT NULL,
                sitemap TEXT NOT NULL,
                last_modified TEXT
            );

            CREATE TABLE rendered_bodies (
                url_id INTEGER PRIMARY KEY,
                html BLOB NOT NULL
            );

            CREATE TABLE screenshots (
                url_id INTEGER PRIMARY KEY,
                png BLOB NOT NULL
            );
            """)
        }

        // Custom extraction, custom search and near-duplicate detection.
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
            ALTER TABLE urls ADD COLUMN simhash INTEGER;

            CREATE TABLE extractions (
                url_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (url_id, name)
            ) WITHOUT ROWID;
            CREATE INDEX extractions_on_name ON extractions(name);

            -- Only matches are stored, so "pages matching X" is a simple join.
            CREATE TABLE search_hits (
                url_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                PRIMARY KEY (url_id, name)
            ) WITHOUT ROWID;
            CREATE INDEX search_hits_on_name ON search_hits(name);

            CREATE TABLE near_duplicates (
                url_id INTEGER NOT NULL,
                other_id INTEGER NOT NULL,
                similarity REAL NOT NULL,
                PRIMARY KEY (url_id, other_id)
            ) WITHOUT ROWID;
            """)
        }

        // Google Search Console, GA4 and PageSpeed data joined onto crawled URLs. 2.0 dropped the
        // Google integrations; the columns stay so packages from 1.x still open.
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
            ALTER TABLE urls ADD COLUMN gsc_clicks INTEGER;
            ALTER TABLE urls ADD COLUMN gsc_impressions INTEGER;
            ALTER TABLE urls ADD COLUMN gsc_ctr REAL;
            ALTER TABLE urls ADD COLUMN gsc_position REAL;
            ALTER TABLE urls ADD COLUMN ga4_sessions INTEGER;
            ALTER TABLE urls ADD COLUMN ga4_engaged_sessions INTEGER;
            ALTER TABLE urls ADD COLUMN ga4_page_views INTEGER;
            ALTER TABLE urls ADD COLUMN psi_score REAL;
            ALTER TABLE urls ADD COLUMN psi_lcp_ms REAL;
            ALTER TABLE urls ADD COLUMN psi_cls REAL;
            ALTER TABLE urls ADD COLUMN psi_tbt_ms REAL;
            ALTER TABLE urls ADD COLUMN psi_field_lcp_ms REAL;
            ALTER TABLE urls ADD COLUMN psi_field_cls REAL;
            ALTER TABLE urls ADD COLUMN psi_field_inp_ms REAL;

            CREATE TABLE url_inspections (
                url_id INTEGER PRIMARY KEY,
                verdict TEXT,
                coverage_state TEXT,
                robots_state TEXT,
                indexing_state TEXT,
                google_canonical TEXT,
                user_canonical TEXT,
                last_crawl TEXT,
                mobile_verdict TEXT,
                rich_results_verdict TEXT,
                fetched_at REAL
            );
            """)
        }

        // What a product page's structured data says, for the e-commerce checks.
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
            CREATE TABLE products (
                url_id INTEGER PRIMARY KEY,
                name TEXT,
                brand TEXT,
                entities INTEGER NOT NULL DEFAULT 1,
                entities_no_price INTEGER NOT NULL DEFAULT 0,
                entities_no_availability INTEGER NOT NULL DEFAULT 0,
                variants INTEGER NOT NULL,
                with_price INTEGER NOT NULL,
                with_availability INTEGER NOT NULL,
                with_identifier INTEGER NOT NULL,
                with_sku INTEGER NOT NULL,
                low_price REAL,
                high_price REAL,
                currency TEXT,
                availability TEXT,
                images INTEGER NOT NULL,
                review_count INTEGER,
                rating REAL
            );
            """)
        }

        // Lighthouse speed results, mobile (lh_m_) and desktop (lh_d_), run locally after a crawl.
        migrator.registerMigration("v6") { db in
            var sql = ""
            for device in ["m", "d"] {
                for column in ["score", "lcp_ms", "cls", "tbt_ms", "fcp_ms", "si_ms"] {
                    sql += "ALTER TABLE urls ADD COLUMN lh_\(device)_\(column) REAL;\n"
                }
            }
            sql += """
            CREATE TABLE lighthouse_reports (
                url_id INTEGER NOT NULL,
                device TEXT NOT NULL,
                opportunities TEXT,
                report_html BLOB,
                error TEXT,
                ran_at REAL NOT NULL,
                PRIMARY KEY (url_id, device)
            ) WITHOUT ROWID;
            """
            try db.execute(sql: sql)
        }

        // Which Shopify template a measured page stands for ("Product", "Collection"…), so a slow
        // template is reported once rather than as every page that uses it.
        migrator.registerMigration("v7") { db in
            try db.execute(sql: "ALTER TABLE lighthouse_reports ADD COLUMN template TEXT")
        }

        return migrator
    }
}
