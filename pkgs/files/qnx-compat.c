/* SPDX-License-Identifier: MIT
 * bbnix QNX libc compat shim.
 *
 * QNX 8 / BB10's libc is missing a few POSIX/C functions that portable Unix
 * software (ncurses widec, mosh) assumes are present:
 *
 *   - tsearch/tfind/tdelete (<search.h> binary-tree API): absent entirely
 *     (QNX ships only the hsearch hash-table API). ncurses' extended-color
 *     pair cache (new_pair.c) uses these unconditionally.
 *   - wcwidth/wcswidth (<wchar.h>): not provided or even declared. On stock
 *     QNX these live in QNX's *own* ncurses, which is circular when we are the
 *     ones building ncurses. Needed by any UTF-8 TUI (ncurses widec, mosh).
 *   - __cxa_throw_bad_array_new_length: a C++ ABI runtime symbol GCC 9 emits
 *     for `new T[n]` overflow checks, added to libsupc++ in GCC 4.9 -- absent
 *     in the device's libstdc++ 4.8.3. Any C++ built with the GCC 9 frontend
 *     (protobuf, mosh) references it. (The companion sized-operator-delete gap
 *     is handled at compile time by -fno-sized-deallocation, see qnx-common.)
 *
 * Built as libbbnixcompat.so and linked ahead of libc; the symbols are plain
 * libc names so they satisfy the undefined references directly.
 */

#include <stdlib.h>
#include <wchar.h>

/* ------------------------------------------------------------------ *
 * tsearch(3) family -- unbalanced binary search tree.
 *
 * An unbalanced tree is functionally correct (the consumers only need
 * insert/find/delete, not balance guarantees); ncurses' caches are small.
 * The node's first member is the key pointer, so a returned node, read as
 * (void *), yields the stored key -- the contract callers rely on.
 * ------------------------------------------------------------------ */

typedef struct bb_tnode {
    const void *key;
    struct bb_tnode *left;
    struct bb_tnode *right;
} bb_tnode;

void *tsearch(const void *key, void **rootp,
              int (*compar)(const void *, const void *))
{
    if (rootp == NULL)
        return NULL;

    bb_tnode **slot = (bb_tnode **) rootp;
    while (*slot != NULL) {
        int c = compar(key, (*slot)->key);
        if (c == 0)
            return *slot;                 /* already present */
        slot = (c < 0) ? &(*slot)->left : &(*slot)->right;
    }

    bb_tnode *node = malloc(sizeof(*node));
    if (node != NULL) {
        node->key = key;
        node->left = node->right = NULL;
        *slot = node;
    }
    return node;
}

void *tfind(const void *key, void *const *rootp,
            int (*compar)(const void *, const void *))
{
    if (rootp == NULL)
        return NULL;

    bb_tnode *const *slot = (bb_tnode *const *) rootp;
    while (*slot != NULL) {
        int c = compar(key, (*slot)->key);
        if (c == 0)
            return *slot;
        slot = (c < 0) ? &(*slot)->left : &(*slot)->right;
    }
    return NULL;
}

/* POSIX: returns a pointer to the parent of the deleted node (or NULL if the
 * key was not found). Callers in ncurses ignore the value beyond found/not. */
void *tdelete(const void *restrict key, void **restrict rootp,
              int (*compar)(const void *, const void *))
{
    if (rootp == NULL)
        return NULL;

    bb_tnode **slot = (bb_tnode **) rootp;
    bb_tnode *parent = NULL;
    while (*slot != NULL) {
        int c = compar(key, (*slot)->key);
        if (c == 0)
            break;
        parent = *slot;
        slot = (c < 0) ? &(*slot)->left : &(*slot)->right;
    }
    if (*slot == NULL)
        return NULL;                      /* not found */

    bb_tnode *victim = *slot;
    if (victim->left == NULL) {
        *slot = victim->right;
    } else if (victim->right == NULL) {
        *slot = victim->left;
    } else {
        /* Two children: splice in the in-order successor (min of right). */
        bb_tnode **succ = &victim->right;
        while ((*succ)->left != NULL)
            succ = &(*succ)->left;
        bb_tnode *s = *succ;
        *succ = s->right;                 /* detach successor */
        s->left = victim->left;
        s->right = victim->right;
        *slot = s;
    }
    free(victim);
    return parent != NULL ? (void *) parent : (void *) rootp;
}

/* twalk(3): depth-first traversal. VISIT is normally from <search.h>; QNX
 * does not ship it, so define it locally with the standard ordering/values. */
typedef enum { preorder, postorder, endorder, leaf } VISIT;

static void bb_twalk(const bb_tnode *node,
                     void (*action)(const void *, VISIT, int), int depth)
{
    if (node == NULL)
        return;
    if (node->left == NULL && node->right == NULL) {
        action(node, leaf, depth);
    } else {
        action(node, preorder, depth);
        bb_twalk(node->left, action, depth + 1);
        action(node, postorder, depth);
        bb_twalk(node->right, action, depth + 1);
        action(node, endorder, depth);
    }
}

void twalk(const void *root, void (*action)(const void *, VISIT, int))
{
    bb_twalk((const bb_tnode *) root, action, 0);
}

/* ------------------------------------------------------------------ *
 * wcwidth(3) / wcswidth(3) -- Markus Kuhn's public-domain implementation
 * (https://www.cl.cam.ac.uk/~mgk25/ucs/wcwidth.c), the same logic ncurses
 * bundles internally. Returns the column width of a Unicode code point:
 * -1 for control/non-printable, 0 for combining marks, 1 or 2 otherwise.
 * ------------------------------------------------------------------ */

struct bb_interval {
    int first;
    int last;
};

static int bb_bisearch(wchar_t ucs, const struct bb_interval *table, int max)
{
    int min = 0;
    if (ucs < table[0].first || ucs > table[max].last)
        return 0;
    while (max >= min) {
        int mid = (min + max) / 2;
        if (ucs > table[mid].last)
            min = mid + 1;
        else if (ucs < table[mid].first)
            max = mid - 1;
        else
            return 1;
    }
    return 0;
}

int wcwidth(wchar_t ucs)
{
    /* Sorted list of non-overlapping zero-width (combining) intervals,
     * generated from Unicode 5.0 data (general categories Mn, Me, plus
     * SOFT HYPHEN and ZERO WIDTH SPACE). */
    static const struct bb_interval combining[] = {
        {0x0300, 0x036F}, {0x0483, 0x0486}, {0x0488, 0x0489},
        {0x0591, 0x05BD}, {0x05BF, 0x05BF}, {0x05C1, 0x05C2},
        {0x05C4, 0x05C5}, {0x05C7, 0x05C7}, {0x0600, 0x0603},
        {0x0610, 0x0615}, {0x064B, 0x065E}, {0x0670, 0x0670},
        {0x06D6, 0x06E4}, {0x06E7, 0x06E8}, {0x06EA, 0x06ED},
        {0x070F, 0x070F}, {0x0711, 0x0711}, {0x0730, 0x074A},
        {0x07A6, 0x07B0}, {0x07EB, 0x07F3}, {0x0901, 0x0902},
        {0x093C, 0x093C}, {0x0941, 0x0948}, {0x094D, 0x094D},
        {0x0951, 0x0954}, {0x0962, 0x0963}, {0x0981, 0x0981},
        {0x09BC, 0x09BC}, {0x09C1, 0x09C4}, {0x09CD, 0x09CD},
        {0x09E2, 0x09E3}, {0x0A01, 0x0A02}, {0x0A3C, 0x0A3C},
        {0x0A41, 0x0A42}, {0x0A47, 0x0A48}, {0x0A4B, 0x0A4D},
        {0x0A70, 0x0A71}, {0x0A81, 0x0A82}, {0x0ABC, 0x0ABC},
        {0x0AC1, 0x0AC5}, {0x0AC7, 0x0AC8}, {0x0ACD, 0x0ACD},
        {0x0AE2, 0x0AE3}, {0x0B01, 0x0B01}, {0x0B3C, 0x0B3C},
        {0x0B3F, 0x0B3F}, {0x0B41, 0x0B43}, {0x0B4D, 0x0B4D},
        {0x0B56, 0x0B56}, {0x0B82, 0x0B82}, {0x0BC0, 0x0BC0},
        {0x0BCD, 0x0BCD}, {0x0C3E, 0x0C40}, {0x0C46, 0x0C48},
        {0x0C4A, 0x0C4D}, {0x0C55, 0x0C56}, {0x0CBC, 0x0CBC},
        {0x0CBF, 0x0CBF}, {0x0CC6, 0x0CC6}, {0x0CCC, 0x0CCD},
        {0x0CE2, 0x0CE3}, {0x0D41, 0x0D43}, {0x0D4D, 0x0D4D},
        {0x0DCA, 0x0DCA}, {0x0DD2, 0x0DD4}, {0x0DD6, 0x0DD6},
        {0x0E31, 0x0E31}, {0x0E34, 0x0E3A}, {0x0E47, 0x0E4E},
        {0x0EB1, 0x0EB1}, {0x0EB4, 0x0EB9}, {0x0EBB, 0x0EBC},
        {0x0EC8, 0x0ECD}, {0x0F18, 0x0F19}, {0x0F35, 0x0F35},
        {0x0F37, 0x0F37}, {0x0F39, 0x0F39}, {0x0F71, 0x0F7E},
        {0x0F80, 0x0F84}, {0x0F86, 0x0F87}, {0x0F90, 0x0F97},
        {0x0F99, 0x0FBC}, {0x0FC6, 0x0FC6}, {0x102D, 0x1030},
        {0x1032, 0x1032}, {0x1036, 0x1037}, {0x1039, 0x1039},
        {0x1058, 0x1059}, {0x1160, 0x11FF}, {0x135F, 0x135F},
        {0x1712, 0x1714}, {0x1732, 0x1734}, {0x1752, 0x1753},
        {0x1772, 0x1773}, {0x17B4, 0x17B5}, {0x17B7, 0x17BD},
        {0x17C6, 0x17C6}, {0x17C9, 0x17D3}, {0x17DD, 0x17DD},
        {0x180B, 0x180D}, {0x18A9, 0x18A9}, {0x1920, 0x1922},
        {0x1927, 0x1928}, {0x1932, 0x1932}, {0x1939, 0x193B},
        {0x1A17, 0x1A18}, {0x1B00, 0x1B03}, {0x1B34, 0x1B34},
        {0x1B36, 0x1B3A}, {0x1B3C, 0x1B3C}, {0x1B42, 0x1B42},
        {0x1B6B, 0x1B73}, {0x1DC0, 0x1DCA}, {0x1DFE, 0x1DFF},
        {0x200B, 0x200F}, {0x202A, 0x202E}, {0x2060, 0x2063},
        {0x206A, 0x206F}, {0x20D0, 0x20EF}, {0x302A, 0x302F},
        {0x3099, 0x309A}, {0xA806, 0xA806}, {0xA80B, 0xA80B},
        {0xA825, 0xA826}, {0xFB1E, 0xFB1E}, {0xFE00, 0xFE0F},
        {0xFE20, 0xFE23}, {0xFEFF, 0xFEFF}, {0xFFF9, 0xFFFB},
        {0x10A01, 0x10A03}, {0x10A05, 0x10A06}, {0x10A0C, 0x10A0F},
        {0x10A38, 0x10A3A}, {0x10A3F, 0x10A3F}, {0x1D167, 0x1D169},
        {0x1D173, 0x1D182}, {0x1D185, 0x1D18B}, {0x1D1AA, 0x1D1AD},
        {0x1D242, 0x1D244}, {0xE0001, 0xE0001}, {0xE0020, 0xE007F},
        {0xE0100, 0xE01EF}
    };

    if (ucs == 0)
        return 0;
    if (ucs < 32 || (ucs >= 0x7f && ucs < 0xa0))
        return -1;

    if (bb_bisearch(ucs, combining,
                    (int) (sizeof(combining) / sizeof(combining[0]) - 1)))
        return 0;

    /* Fixed-width wide (CJK etc.) ranges. */
    return 1 +
        (ucs >= 0x1100 &&
         (ucs <= 0x115F ||                     /* Hangul Jamo init. */
          ucs == 0x2329 || ucs == 0x232A ||
          (ucs >= 0x2E80 && ucs <= 0xA4CF && ucs != 0x303F) ||  /* CJK ... Yi */
          (ucs >= 0xAC00 && ucs <= 0xD7A3) ||  /* Hangul Syllables */
          (ucs >= 0xF900 && ucs <= 0xFAFF) ||  /* CJK Compat. Ideographs */
          (ucs >= 0xFE10 && ucs <= 0xFE19) ||  /* Vertical forms */
          (ucs >= 0xFE30 && ucs <= 0xFE6F) ||  /* CJK Compat. Forms */
          (ucs >= 0xFF00 && ucs <= 0xFF60) ||  /* Fullwidth Forms */
          (ucs >= 0xFFE0 && ucs <= 0xFFE6) ||
          (ucs >= 0x20000 && ucs <= 0x2FFFD) ||
          (ucs >= 0x30000 && ucs <= 0x3FFFD)));
}

int wcswidth(const wchar_t *pwcs, size_t n)
{
    int width = 0;
    for (; *pwcs && n-- > 0; pwcs++) {
        int w = wcwidth(*pwcs);
        if (w < 0)
            return -1;
        width += w;
    }
    return width;
}

/* ------------------------------------------------------------------ *
 * C++ ABI: __cxa_throw_bad_array_new_length (libsupc++, GCC >= 4.9).
 *
 * Called when `new T[n]` would overflow. The standard behaviour is to throw
 * std::bad_array_new_length, but that type is itself absent from the 4.8.3
 * libstdc++ headers, so we cannot construct it here. Aborting is an acceptable
 * terminal action for this dev-tool userland: it only fires on an impossible
 * allocation size, never in normal operation. The symbol has C linkage.
 * ------------------------------------------------------------------ */
void __cxa_throw_bad_array_new_length(void)
{
    abort();
}
