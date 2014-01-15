# Notes for converting OSQA to Discourse

## Getting data from OSQA

This query selects all posts, along with their user ids, user emails,
topic ids, usernames and topic names.\

    SELECT
     		fn.id AS id,
     		fn.title AS title,
     		fn.body AS body,
     		fn.added_at AS added_at,
     		fn.last_activity_at AS last_activity_at,
     		fn.author_id,
     		u.username,
     		u.email,
     		fn.parent_id,
     		fn.tagnames AS tags,
     		fn.node_type AS node_type,
     		fn.discourse_id AS discourse_id
     	FROM forum_node fn
     	JOIN auth_user u ON fn.author_id=u.id
     	WHERE fn.discourse_id='0'
     	ORDER BY node_type DESC,id ASC
            LIMIT #{offset.to_s}, 500;

This query is used for getting user info:

    SELECT id, username,
           email, last_login,
           is_active, is_superuser
       FROM auth_user u
       ORDER BY id ASC
       LIMIT #{offset}, 50;


