/* Aggregates by value for the C ABI tests (x86-64 System V classes). */
typedef struct { double a; double b; } dd;          /* SSE, SSE */
typedef struct { int i; float f; } i_f;             /* INTEGER (mixed eightbyte) */
typedef struct { float x; float y; } ff;            /* SSE <2 x float> */
typedef struct { char c; double d; } cd;            /* INTEGER, SSE */
typedef struct { double a, b, c; } big;             /* MEMORY */

dd dd_scale(dd v, double s) { dd r = { v.a * s, v.b * s }; return r; }
i_f if_bump(i_f v) { i_f r = { v.i + 1, v.f * 2 }; return r; }
ff ff_swap(ff v) { ff r = { v.y, v.x }; return r; }
cd cd_mix(cd v) { cd r = { v.c + 1, v.d + 0.5 }; return r; }
big big_sum(big v, big w) { big r = { v.a + w.a, v.b + w.b, v.c + w.c }; return r; }
double big_dot(big v, big w) { return v.a * w.a + v.b * w.b + v.c * w.c; }

/* C callers of `@cfunction` pointers: the callee side of the same classes */
dd cb_dd(dd (*f)(dd, double), dd v, double s) { return f(v, s); }
i_f cb_if(i_f (*f)(i_f), i_f v) { return f(v); }
ff cb_ff(ff (*f)(ff), ff v) { return f(v); }
cd cb_cd(cd (*f)(cd), cd v) { return f(v); }
big cb_big(big (*f)(big, big), big v, big w) { return f(v, w); }
/* out of integer registers: `z` is passed in memory */
double cb_many(double (*f)(long, long, long, long, long, dd, i_f, cd), dd x, i_f y, cd z) {
    return f(1, 2, 3, 4, 5, x, y, z);
}
signed char cb_schar(signed char (*f)(signed char, unsigned short), signed char x, unsigned short y) {
    return f(x, y);
}
