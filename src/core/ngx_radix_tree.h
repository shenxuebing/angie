#ifndef _NGX_RADIX_TREE_H_INCLUDED_
#define _NGX_RADIX_TREE_H_INCLUDED_


#include <ngx_config.h>
#include <ngx_core.h>


typedef struct ngx_radix_node_s  ngx_radix_node_t;

struct ngx_radix_node_s {
    uintptr_t          value;
    ngx_radix_node_t  *right;
    ngx_radix_node_t  *left;
};


typedef struct {
    ngx_radix_node_t  *root;
    ngx_pool_t        *pool;
    ngx_radix_node_t  *free;
    char              *start;
    size_t             size;
} ngx_radix_tree_t;


ngx_radix_tree_t *ngx_radix_tree_create(ngx_pool_t *pool);
ngx_int_t ngx_radix32tree_insert(ngx_radix_tree_t *tree,
                                 uint32_t key, uint32_t mask, uintptr_t value);
void ngx_radix32tree_delete(ngx_radix_tree_t *tree,
                            uint32_t key, uint32_t mask);
uintptr_t ngx_radix32tree_find(ngx_radix_tree_t *tree, uint32_t key);


#endif /* _NGX_RADIX_TREE_H_INCLUDED_ */
