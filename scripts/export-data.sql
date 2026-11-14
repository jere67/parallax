-- One JSON document with a server's whole record, read by scripts/export-data.sh and taken by
-- accounts/transfer.jac. One statement, so every table is read from the same snapshot.
SELECT json_build_object(
    'format', 'parallax-data',
    'version', 1,
    'exported_at', now(),
    'anchors', (
        SELECT coalesce(json_agg(json_build_array(
            id, kind, arch_type, arch_module, fingerprint, root_id, src, dst, undirected, props,
            format_version, version, seq) ORDER BY seq), '[]')
        FROM anchors),
    'graph_types', (
        SELECT coalesce(json_agg(json_build_array(type_name, ancestor)), '[]') FROM graph_types),
    'identity_users', (
        SELECT coalesce(json_agg(json_build_array(user_id, doc)), '[]') FROM identity_users),
    'identity_lookups', (
        SELECT coalesce(json_agg(json_build_array(value_normalized, user_id)), '[]')
        FROM identity_lookups),
    'sso_lookups', (
        SELECT coalesce(json_agg(json_build_array(provider, external_id, user_id)), '[]')
        FROM sso_lookups)
)
