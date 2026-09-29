// comment   with   spaces
U0 F() {//Doc
    x = 1;// tight
    y = 2;      // wide
    z = 3; /* inline */ w = 4;
    a =  /* mid */  b;
    /* block */
    c = d;   /* trailing */
    /* multi
     line   comment */ e = f;
    g = h; /* start
     end */ i = j;
    Foo(a, // one
            b);
    Bar(a,/* c */b);
    //no space
    //  two   spaces
}   // after close
U0 G()
{//Doc2
    q = 1;
}
x = 1;/* c */
