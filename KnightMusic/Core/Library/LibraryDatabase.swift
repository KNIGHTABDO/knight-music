import Foundation
import GRDB

/// One SQLite file per account: Application Support/Accounts/<accountId>/library.sqlite.
/// Holds the mirror of the server library plus tables used by playback and downloads.
final class LibraryDatabase: @unchecked Sendable {
    let accountId: UUID
    let pool: DatabasePool
    let url: URL

    // MARK: - Locations

    static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func accountDirectory(_ id: UUID) -> URL {
        applicationSupport.appendingPathComponent("Accounts", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func deleteFiles(for id: UUID) {
        try? FileManager.default.removeItem(at: accountDirectory(id))
    }

    // MARK: - Lifecycle

    init(accountId: UUID) throws {
        self.accountId = accountId
        let directory = Self.accountDirectory(accountId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("library.sqlite")

        var configuration = Configuration()
        configuration.label = "library"
        configuration.busyMode = .timeout(8)
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(pool)
        Log.database.info("opened \(url.path)")
    }

    func close() {
        try? pool.close()
    }

    // MARK: - Sync state helpers

    func stateValue(_ key: String) async -> String? {
        try? await pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [key])
        }
    }

    func setStateValue(_ value: String, for key: String) async {
        do {
            try await pool.write { db in
                try db.execute(sql: "INSERT INTO syncState(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [key, value])
            }
        } catch {
            Log.database.error("setStateValue(\(key)) failed: \(error)")
        }
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE artist (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                coverArt TEXT,
                artistImageUrl TEXT,
                albumCount INTEGER,
                starred DATETIME,
                sortName TEXT
            );
            CREATE INDEX artist_starred ON artist(starred);
            CREATE INDEX artist_name ON artist(name COLLATE NOCASE);

            CREATE TABLE album (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                artist TEXT,
                artistId TEXT,
                coverArt TEXT,
                songCount INTEGER,
                duration INTEGER,
                playCount INTEGER,
                played DATETIME,
                created DATETIME,
                starred DATETIME,
                year INTEGER,
                genre TEXT,
                userRating INTEGER,
                sortName TEXT,
                isCompilation BOOLEAN
            );
            CREATE INDEX album_artistId ON album(artistId);
            CREATE INDEX album_starred ON album(starred);
            CREATE INDEX album_created ON album(created);
            CREATE INDEX album_played ON album(played);
            CREATE INDEX album_playCount ON album(playCount);
            CREATE INDEX album_genre ON album(genre);
            CREATE INDEX album_name ON album(name COLLATE NOCASE);

            CREATE TABLE song (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                album TEXT,
                albumId TEXT,
                artist TEXT,
                artistId TEXT,
                track INTEGER,
                discNumber INTEGER,
                year INTEGER,
                genre TEXT,
                coverArt TEXT,
                size INTEGER,
                contentType TEXT,
                suffix TEXT,
                duration INTEGER,
                bitRate INTEGER,
                samplingRate INTEGER,
                path TEXT,
                playCount INTEGER,
                played DATETIME,
                created DATETIME,
                starred DATETIME,
                userRating INTEGER,
                bpm INTEGER,
                comment TEXT,
                sortName TEXT,
                displayComposer TEXT,
                replayGain TEXT
            );
            CREATE INDEX song_albumId ON song(albumId);
            CREATE INDEX song_artistId ON song(artistId);
            CREATE INDEX song_starred ON song(starred);
            CREATE INDEX song_created ON song(created);
            CREATE INDEX song_played ON song(played);
            CREATE INDEX song_playCount ON song(playCount);
            CREATE INDEX song_genre ON song(genre);
            CREATE INDEX song_title ON song(title COLLATE NOCASE);

            CREATE TABLE playlist (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                comment TEXT,
                owner TEXT,
                "public" BOOLEAN,
                songCount INTEGER,
                duration INTEGER,
                created DATETIME,
                changed DATETIME,
                coverArt TEXT
            );

            CREATE TABLE playlistEntry (
                playlistId TEXT NOT NULL,
                position INTEGER NOT NULL,
                songId TEXT NOT NULL,
                PRIMARY KEY (playlistId, position)
            );
            CREATE INDEX playlistEntry_songId ON playlistEntry(songId);

            CREATE TABLE genre (
                value TEXT PRIMARY KEY NOT NULL,
                songCount INTEGER,
                albumCount INTEGER
            );

            CREATE TABLE radioStation (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                streamUrl TEXT NOT NULL,
                homePageUrl TEXT
            );

            CREATE TABLE syncState (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT
            );

            CREATE TABLE homeList (
                kind TEXT NOT NULL,
                position INTEGER NOT NULL,
                albumId TEXT NOT NULL,
                PRIMARY KEY (kind, position)
            );

            CREATE TABLE topSong (
                artistId TEXT NOT NULL,
                position INTEGER NOT NULL,
                songId TEXT NOT NULL,
                PRIMARY KEY (artistId, position)
            );

            CREATE TABLE lyrics (
                songId TEXT PRIMARY KEY NOT NULL,
                json TEXT NOT NULL,
                fetchedAt DATETIME NOT NULL
            );

            CREATE TABLE artistInfo (
                artistId TEXT PRIMARY KEY NOT NULL,
                json TEXT NOT NULL,
                fetchedAt DATETIME NOT NULL
            );

            CREATE TABLE download (
                songId TEXT PRIMARY KEY NOT NULL,
                state TEXT NOT NULL,
                progress REAL,
                bytes INTEGER,
                relativePath TEXT,
                addedAt DATETIME,
                errorMessage TEXT
            );
            CREATE INDEX download_state ON download(state);

            CREATE TABLE cachedSong (
                songId TEXT PRIMARY KEY NOT NULL,
                relativePath TEXT,
                bytes INTEGER,
                lastAccess DATETIME,
                quality TEXT
            );
            CREATE INDEX cachedSong_lastAccess ON cachedSong(lastAccess);

            CREATE TABLE pendingScrobble (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                songId TEXT NOT NULL,
                time DATETIME NOT NULL,
                submission BOOLEAN NOT NULL
            );
            """)

            // Full-text search: external-content FTS5 tables kept in sync by triggers.
            // unicode61 + remove_diacritics 2 folds Latin accents and tokenizes Arabic script as words.
            try db.execute(sql: """
            CREATE VIRTUAL TABLE songFts USING fts5(
                title, artist, album,
                content='song', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2', prefix='1 2 3 4'
            );
            CREATE TRIGGER song_fts_ai AFTER INSERT ON song BEGIN
                INSERT INTO songFts(rowid, title, artist, album) VALUES (new.rowid, new.title, new.artist, new.album);
            END;
            CREATE TRIGGER song_fts_ad AFTER DELETE ON song BEGIN
                INSERT INTO songFts(songFts, rowid, title, artist, album) VALUES ('delete', old.rowid, old.title, old.artist, old.album);
            END;
            CREATE TRIGGER song_fts_au AFTER UPDATE OF title, artist, album ON song
            WHEN old.title IS NOT new.title OR old.artist IS NOT new.artist OR old.album IS NOT new.album BEGIN
                INSERT INTO songFts(songFts, rowid, title, artist, album) VALUES ('delete', old.rowid, old.title, old.artist, old.album);
                INSERT INTO songFts(rowid, title, artist, album) VALUES (new.rowid, new.title, new.artist, new.album);
            END;

            CREATE VIRTUAL TABLE albumFts USING fts5(
                name, artist,
                content='album', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2', prefix='1 2 3 4'
            );
            CREATE TRIGGER album_fts_ai AFTER INSERT ON album BEGIN
                INSERT INTO albumFts(rowid, name, artist) VALUES (new.rowid, new.name, new.artist);
            END;
            CREATE TRIGGER album_fts_ad AFTER DELETE ON album BEGIN
                INSERT INTO albumFts(albumFts, rowid, name, artist) VALUES ('delete', old.rowid, old.name, old.artist);
            END;
            CREATE TRIGGER album_fts_au AFTER UPDATE OF name, artist ON album
            WHEN old.name IS NOT new.name OR old.artist IS NOT new.artist BEGIN
                INSERT INTO albumFts(albumFts, rowid, name, artist) VALUES ('delete', old.rowid, old.name, old.artist);
                INSERT INTO albumFts(rowid, name, artist) VALUES (new.rowid, new.name, new.artist);
            END;

            CREATE VIRTUAL TABLE artistFts USING fts5(
                name,
                content='artist', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2', prefix='1 2 3 4'
            );
            CREATE TRIGGER artist_fts_ai AFTER INSERT ON artist BEGIN
                INSERT INTO artistFts(rowid, name) VALUES (new.rowid, new.name);
            END;
            CREATE TRIGGER artist_fts_ad AFTER DELETE ON artist BEGIN
                INSERT INTO artistFts(artistFts, rowid, name) VALUES ('delete', old.rowid, old.name);
            END;
            CREATE TRIGGER artist_fts_au AFTER UPDATE OF name ON artist
            WHEN old.name IS NOT new.name BEGIN
                INSERT INTO artistFts(artistFts, rowid, name) VALUES ('delete', old.rowid, old.name);
                INSERT INTO artistFts(rowid, name) VALUES (new.rowid, new.name);
            END;
            """)
        }
        return migrator
    }
}
