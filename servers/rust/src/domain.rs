use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use rusqlite::{Connection, OptionalExtension, Row, TransactionBehavior, params};
use serde::Serialize;

use crate::{ApiError, auth::Viewer, now_ms};

pub const MAX_ID: i64 = 9_007_199_254_740_991;
const FEED: &str = "SELECT p.id, p.title, p.body, p.comment_count, p.created_at, u.id, u.name FROM feed_items f JOIN posts p ON p.id = f.post_id JOIN users u ON u.id = p.user_id WHERE f.user_id = ? AND (f.created_at, f.post_id) < (?, ?) ORDER BY f.created_at DESC, f.post_id DESC LIMIT ?";
const POST: &str = "SELECT p.id, p.title, p.body, p.comment_count, p.created_at, u.id, u.name FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?";
const COMMENTS: &str = "SELECT c.id, c.body, c.created_at, u.id, u.name FROM comments c JOIN users u ON u.id = c.user_id WHERE c.post_id = ? ORDER BY c.id DESC LIMIT 20";

pub fn positive_integer(value: &str, maximum: i64) -> Option<i64> {
    if value.is_empty() || !value.bytes().all(|c| c.is_ascii_digit()) {
        return None;
    }
    value.parse::<i64>().ok().filter(|&n| n > 0 && n <= maximum)
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Post {
    id: i64,
    title: String,
    body: String,
    word_count: usize,
    reading_minutes: usize,
    tags: Vec<String>,
    comment_count: i64,
    created_at: i64,
    author: Viewer,
}

fn word_count(body: &str) -> usize {
    let bytes = body.as_bytes();
    let Some((&first, rest)) = bytes.split_first() else {
        return 0;
    };
    // A later word starts wherever a space precedes a non-space byte; u8 sums over at most 255
    // pairs keep the count in byte lanes, which LLVM vectorizes.
    let later_words: usize = bytes
        .chunks(255)
        .zip(rest.chunks(255))
        .map(|(previous, current)| {
            let starts: u8 = previous
                .iter()
                .zip(current)
                .map(|(&previous, &current)| u8::from(previous == b' ' && current != b' '))
                .sum();
            usize::from(starts)
        })
        .sum();
    usize::from(first != b' ') + later_words
}

fn tags(body: &str) -> Vec<String> {
    let mut tags: Vec<String> = Vec::with_capacity(5);
    for (hash, _) in body.match_indices('#') {
        if hash > 0 && body.as_bytes()[hash - 1] != b' ' {
            continue;
        }
        let rest = &body[hash + 1..];
        let tag = rest.split_once(' ').map_or(rest, |(tag, _)| tag);
        if !tag.is_empty()
            && tag
                .bytes()
                .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_')
            && !tags.iter().any(|existing| existing == tag)
        {
            tags.push(tag.to_owned());
            if tags.len() == 5 {
                break;
            }
        }
    }
    tags
}

impl Post {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        let body: String = row.get(2)?;
        let word_count = word_count(&body);
        let tags = tags(&body);
        Ok(Self {
            id: row.get(0)?,
            title: row.get(1)?,
            body,
            word_count,
            reading_minutes: word_count.div_ceil(200).max(1),
            tags,
            comment_count: row.get(3)?,
            created_at: row.get(4)?,
            author: Viewer {
                id: row.get(5)?,
                name: row.get(6)?,
            },
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FeedItem {
    id: i64,
    title: String,
    excerpt: String,
    word_count: usize,
    reading_minutes: usize,
    tags: Vec<String>,
    comment_count: i64,
    created_at: i64,
    author: Viewer,
}
impl From<Post> for FeedItem {
    fn from(post: Post) -> Self {
        let mut excerpt = post.body;
        if excerpt.len() > 200 {
            let cut = excerpt[..200].rfind(' ').unwrap_or(200);
            excerpt.truncate(cut);
            excerpt.push_str("...");
        }
        Self {
            id: post.id,
            title: post.title,
            excerpt,
            word_count: post.word_count,
            reading_minutes: post.reading_minutes,
            tags: post.tags,
            comment_count: post.comment_count,
            created_at: post.created_at,
            author: post.author,
        }
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Feed {
    viewer: Viewer,
    items: Vec<FeedItem>,
    next_cursor: Option<String>,
}

pub fn feed(
    connection: &Connection,
    viewer: Viewer,
    limit: i64,
    cursor: (i64, i64),
) -> Result<Feed, ApiError> {
    let mut statement = connection.prepare_cached(FEED)?;
    let items = statement
        .query_map(
            params![viewer.id, cursor.0, cursor.1, limit],
            Post::from_row,
        )?
        .map(|post| post.map(FeedItem::from))
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let next_cursor = if items.len() == limit as usize {
        items
            .last()
            .map(|item| URL_SAFE_NO_PAD.encode(format!("{}:{}", item.created_at, item.id)))
    } else {
        None
    };
    Ok(Feed {
        viewer,
        items,
        next_cursor,
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Comment {
    id: i64,
    body: String,
    created_at: i64,
    author: Viewer,
}
#[derive(Serialize)]
pub struct Detail {
    post: Post,
    comments: Vec<Comment>,
}

pub fn detail(connection: &Connection, id: i64) -> Result<Detail, ApiError> {
    let post = connection
        .prepare_cached(POST)?
        .query_row([id], Post::from_row)
        .optional()?
        .ok_or_else(ApiError::not_found)?;
    let comments = connection
        .prepare_cached(COMMENTS)?
        .query_map([id], |row| {
            Ok(Comment {
                id: row.get(0)?,
                body: row.get(1)?,
                created_at: row.get(2)?,
                author: Viewer {
                    id: row.get(3)?,
                    name: row.get(4)?,
                },
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(Detail { post, comments })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreatedComment {
    id: i64,
    post_id: i64,
    body: String,
    created_at: u64,
    author: Viewer,
}

pub fn create(
    connection: &mut Connection,
    id: i64,
    body: String,
    viewer: Viewer,
) -> Result<CreatedComment, ApiError> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if transaction
        .prepare_cached("UPDATE posts SET comment_count = comment_count + 1 WHERE id = ?")?
        .execute([id])?
        == 0
    {
        return Err(ApiError::not_found());
    }
    let created_at = now_ms();
    let comment_id = {
        let mut statement = transaction.prepare_cached(
            "INSERT INTO comments (post_id, user_id, body, created_at) VALUES (?, ?, ?, ?) RETURNING id",
        )?;
        let mut rows = statement.query(params![id, viewer.id, body, created_at as i64])?;
        let comment_id = rows.next()?.ok_or_else(ApiError::internal)?.get(0)?;
        while rows.next()?.is_some() {}
        comment_id
    };
    transaction.commit()?;
    Ok(CreatedComment {
        id: comment_id,
        post_id: id,
        body,
        created_at,
        author: viewer,
    })
}

#[cfg(test)]
mod tests {
    use super::{tags, word_count};

    #[test]
    fn derived_fields_follow_space_separated_words() {
        assert_eq!(word_count(""), 0);
        assert_eq!(word_count("   "), 0);
        assert_eq!(word_count(" a  b c "), 3);
        assert_eq!(word_count("a\tb"), 1);
        assert_eq!(word_count(&"a ".repeat(300)), 300);
        assert_eq!(word_count(&" a".repeat(128)), 128);
        assert_eq!(word_count(&" ab".repeat(170)), 170);
        assert_eq!(
            tags("#a x#b ##c # #d_1 #E #a #f- #g  #h #i #j"),
            ["a", "d_1", "g", "h", "i"]
        );
        assert_eq!(tags("#tail"), ["tail"]);
        assert!(tags("no tags here #").is_empty());
    }
}
