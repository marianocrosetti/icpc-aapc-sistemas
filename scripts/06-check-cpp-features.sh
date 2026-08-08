#!/bin/bash
# Verifica qué features de C++ están realmente disponibles con el compilador y los flags EXACTOS
# que usa el autojudge del contest.
#
# Existe porque la respuesta no es obvia: el estándar de C++ no lo elige BOCA sino el script
# `compile/cc` **del paquete del problema**. Los paquetes de `rbx` compilan con:
#
#     g++ -std=c++20 -O2 -lm -static
#
# ...pero pedir `-std=c++20` no significa tener C++20 completo: el `g++ 11.4` de Ubuntu 22.04 le
# falta parte (`std::format`, `constexpr std::vector`). Este script mide qué hay de verdad, en vez
# de deducirlo de la versión.
#
# Cada feature va en un snippet independiente y se compila por separado, así una que falla no tapa
# a las demás. Un snippet pasa si compila Y además imprime OK al correr.
#
# Se puede correr en dos lados, y conviene que den lo mismo:
#
#   1) Local, en un contenedor igual al jail (no toca la infra):
#        docker run --rm -v "$PWD/scripts:/w:ro" ubuntu:22.04 bash -c \
#          'apt-get update -qq && apt-get install -y -qq g++ && bash /w/06-check-cpp-features.sh'
#
#   2) Dentro del jail real de una judge (la fuente de verdad):
#        gcloud compute scp scripts/06-check-cpp-features.sh boca-judge-1:/tmp/ --zone=us-central1-a
#        gcloud compute ssh boca-judge-1 --zone=us-central1-a --command='
#          sudo cp /tmp/06-check-cpp-features.sh /home/bocajail/tmp/ &&
#          sudo chroot /home/bocajail bash /tmp/06-check-cpp-features.sh'
#
# Si algún día se cambia el compilador del jail o el empaquetador cambia el `-std`, correr esto de
# nuevo antes del contest.

FLAGS="${FLAGS:--std=c++20 -O2 -lm -static}"
DIR=$(mktemp -d)
PASS=0; FAIL=0

echo "compilador: $(g++ --version | head -1)"
echo "flags:      $FLAGS"
echo

check() {
  local name="$1"
  local src="$DIR/t.cpp"
  cat > "$src"
  local out
  if ! out=$(g++ $FLAGS -o "$DIR/t.exe" "$src" 2>&1); then
    printf '  %-30s NO COMPILA  %s\n' "$name" "$(echo "$out" | grep -m1 -oE 'error: .*' | cut -c1-80)"
    FAIL=$((FAIL+1)); return
  fi
  local runout
  if ! runout=$("$DIR/t.exe" 2>&1); then
    printf '  %-30s COMPILA PERO CRASHEA\n' "$name"; FAIL=$((FAIL+1)); return
  fi
  if [ "$runout" != "OK" ]; then
    printf '  %-30s RESULTADO INESPERADO: %s\n' "$name" "$(echo "$runout" | head -1 | cut -c1-50)"
    FAIL=$((FAIL+1)); return
  fi
  printf '  %-30s ok\n' "$name"
  PASS=$((PASS+1))
}

echo "=== lo que mas se usa en competitiva ==="

check 'bits/stdc++.h' <<'EOF'
#include <bits/stdc++.h>
int main(){ std::vector<int> v{3,1,2}; std::sort(v.begin(),v.end());
  puts(v[0]==1?"OK":"BAD"); }
EOF

check '<ranges> views basicas' <<'EOF'
#include <ranges>
#include <cstdio>
int main(){
  auto sq = std::views::iota(1,10)
          | std::views::filter([](int x){return x%2==0;})
          | std::views::transform([](int x){return x*x;});
  int s=0; for(int x: sq) s+=x;          // 4+16+36+64 = 120
  puts(s==120?"OK":"BAD");
}
EOF

check '<ranges> reverse/take/drop' <<'EOF'
#include <ranges>
#include <vector>
#include <cstdio>
int main(){
  std::vector<int> v{1,2,3,4,5};
  int s=0; for(int x: v | std::views::reverse | std::views::drop(1) | std::views::take(2)) s+=x;
  puts(s==7?"OK":"BAD");                 // 4+3
}
EOF

check 'ranges::sort + proyeccion' <<'EOF'
#include <algorithm>
#include <ranges>
#include <vector>
#include <cstdio>
struct P{int a,b;};
int main(){
  std::vector<P> v{{3,1},{1,2},{2,3}};
  std::ranges::sort(v, {}, &P::a);
  puts((v[0].a==1&&v[2].a==3)?"OK":"BAD");
}
EOF

check 'ranges::max_element/find/count' <<'EOF'
#include <algorithm>
#include <ranges>
#include <vector>
#include <cstdio>
int main(){
  std::vector<int> v{1,7,3};
  bool ok = *std::ranges::max_element(v)==7
         && std::ranges::find(v,3)!=v.end()
         && std::ranges::count(v,1)==1;
  puts(ok?"OK":"BAD");
}
EOF

check '<bit> popcount/bit_width/rotl' <<'EOF'
#include <bit>
#include <cstdio>
int main(){
  bool ok = std::popcount(0b1011u)==3
         && std::bit_width(8u)==4
         && std::countr_zero(8u)==3
         && std::countl_zero((unsigned)1)==31
         && std::has_single_bit(16u)
         && std::bit_ceil(5u)==8
         && std::rotl(1u,1)==2;
  puts(ok?"OK":"BAD");
}
EOF

check '__builtin_popcount (GNU)' <<'EOF'
#include <cstdio>
int main(){ puts((__builtin_popcountll(255ULL)==8 && __builtin_ctz(8)==3)?"OK":"BAD"); }
EOF

check 'bitset + _Find_first (GNU)' <<'EOF'
#include <bitset>
#include <cstdio>
int main(){ std::bitset<128> b; b.set(37);
  puts((b._Find_first()==37 && b.count()==1)?"OK":"BAD"); }
EOF

echo
echo "=== otras cosas utiles de C++20 ==="

check 'concepts' <<'EOF'
#include <concepts>
#include <cstdio>
template<std::integral T> T dup(T x){ return x*2; }
int main(){ puts(dup(21)==42?"OK":"BAD"); }
EOF

check 'spaceship <=>' <<'EOF'
#include <compare>
#include <cstdio>
struct P{int a,b; auto operator<=>(const P&) const = default; };
int main(){ puts((P{1,2}<P{1,3})?"OK":"BAD"); }
EOF

check '<span>' <<'EOF'
#include <span>
#include <vector>
#include <cstdio>
int main(){ std::vector<int> v{1,2,3}; std::span<int> s(v);
  puts(s.size()==3&&s[1]==2?"OK":"BAD"); }
EOF

check '<numeric> gcd/lcm/midpoint' <<'EOF'
#include <numeric>
#include <cstdio>
int main(){ puts((std::gcd(12,18)==6&&std::lcm(4,6)==12&&std::midpoint(2,8)==5)?"OK":"BAD"); }
EOF

check 'lambdas con template' <<'EOF'
#include <cstdio>
int main(){ auto f=[]<typename T>(T x){return x+x;}; puts(f(21)==42?"OK":"BAD"); }
EOF

check 'std::erase_if' <<'EOF'
#include <vector>
#include <cstdio>
int main(){ std::vector<int> v{1,2,3,4}; std::erase_if(v,[](int x){return x%2;});
  puts(v.size()==2?"OK":"BAD"); }
EOF

check '__int128' <<'EOF'
#include <cstdio>
int main(){ __int128 x=1; for(int i=0;i<100;i++) x*=2;
  puts((x>0 && (long long)(x>>100)==1)?"OK":"BAD"); }
EOF

echo
echo "=== lo que NO esta (esperado: libstdc++ 11 / C++23) ==="

check 'constexpr vector (libstdc++12+)' <<'EOF'
#include <vector>
#include <cstdio>
constexpr int f(){ std::vector<int> v{1,2,3}; return v[2]; }
int main(){ static_assert(f()==3); puts("OK"); }
EOF

check 'std::format (g++13+)' <<'EOF'
#include <format>
#include <cstdio>
int main(){ puts(std::format("{}",42)=="42"?"OK":"BAD"); }
EOF

check 'views::zip (C++23)' <<'EOF'
#include <ranges>
#include <vector>
#include <cstdio>
int main(){ std::vector<int> a{1,2},b{3,4}; int s=0;
  for(auto [x,y]: std::views::zip(a,b)) s+=x*y; puts(s==11?"OK":"BAD"); }
EOF

check 'ranges::to (C++23)' <<'EOF'
#include <ranges>
#include <vector>
#include <cstdio>
int main(){ auto v = std::views::iota(1,4) | std::ranges::to<std::vector<int>>();
  puts(v.size()==3?"OK":"BAD"); }
EOF

echo
echo "pasaron: $PASS   fallaron: $FAIL   (se esperan 4 fallas en la ultima seccion)"
rm -rf "$DIR"
