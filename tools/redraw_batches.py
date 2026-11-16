# A redraw bundle for an image model, laid out like the other ports' (E:\rtk5-upscale\redrawN):
#   py -3 tools/redraw_batches.py [--root D:/upscale/NFS4] <N> <TRACK> [TRACK ...] [--sky]
#   py -3 tools/redraw_batches.py <N> UI     the HUD (redraw_export.py --dump): one picture a sheet, its own prompt
# -> <root>/redrawN: send/<sheet>.png, todo.txt, boxes.json, 프롬프트.md (answers go to received/)
# The redraw work lives on D: (the drive with room; E: and F: are short of space), not in the repository.
# Track textures are 32..128 px squares: nine to a 1024x1024 sheet, each enlarged into a 256 px box on flat grey,
# 64 px apart. See-through parts are flat magenta (the fit step takes the alpha from the original, not from the
# answer). Pictures with the same pixels are sent once (boxes.json lists every name that shares a box).
import sys, json, hashlib, pathlib
from PIL import Image

CANVAS, BOX, GAP, GREY, KEY = 1024, 256, 64, (128, 128, 128), (255, 0, 255)

TRACK_WHAT = '''- 모든 입력은 "모음 그림"이다. 3D 레이싱 게임의 벽·바닥·건물·표지판·나무에 입히는 작은 텍스처(재질 그림) 최대 9장을, 회색 바탕 위에 3x3으로 간격을 두고 늘어놓았다. 하나의 장면이 아니다.'''

TRACK_INSTRUCTIONS = '''첨부한 그림은 1999년 PC 3D 레이싱 게임(니드 포 스피드 4)의 텍스처(벽, 도로, 풀밭, 지붕, 창문, 표지판, 울타리, 나무 등에 입히는 재질 그림)를 확대해서 회색 바탕에 3x3으로 늘어놓은 것이다. 각 칸의 그림은 가로세로 64픽셀쯤의 아주 작은 원본을 확대한 것이라 흐릿하다. 각 칸을 원작 그대로 다시 그려서, 같은 텍스처의 선명한 고해상도판을 만들어 줘.
1. 칸마다 따로따로, 제자리에서, 그 칸 크기 그대로 다시 그린다. 칸끼리 이어 그리거나, 섞거나, 배치를 바꾸거나, 크기를 바꾸지 않는다. 칸 사이와 둘레의 회색은 단색 회색 그대로 둔다. 빈 칸은 회색 그대로 둔다.
2. 구도를 그대로 둔다. 칸 안의 선, 무늬, 벽돌·판자·창틀의 줄 수와 위치, 글자와 화살표의 위치와 크기가 원본과 정확히 겹쳐야 한다. 확대·축소·이동·회전·뒤집기를 하지 않는다.
3. 내용을 그대로 둔다. 새로운 물건·장식·무늬를 더하지 않고, 있는 것을 빼지 않는다. 사람, 자동차, 하늘, 풍경을 그려 넣지 않는다.
4. 색과 빛을 그대로 둔다. 색감, 밝기, 채도, 명암을 원본과 같게 한다. 더 밝게, 더 진하게, 더 화사하게 만들지 않는다. 칸 전체의 평균 밝기와 색이 원본과 같아야 한다(게임 안에서 옆 텍스처와 이어 붙기 때문이다).
5. 화풍은 사진을 바탕으로 한 사실적인 재질 그림이다. 벽돌은 벽돌, 나무판자는 나뭇결, 아스팔트는 아스팔트 알갱이, 풀은 풀잎, 돌은 돌 표면으로, 실제 재질의 자잘한 결을 또렷하게 살린다. 만화풍·수채화풍·매끈한 플라스틱 느낌으로 바꾸지 않는다.
6. 이 그림들은 타일처럼 반복해서 붙이거나 옆 그림과 맞대어 쓴다. 그러므로 각 칸의 네 가장자리는 원본과 같은 색과 무늬로 끝나야 한다. 가장자리에 테두리, 액자, 그림자, 둥근 모서리, 어두워지는 효과(비네팅), 여백을 넣지 않는다. 칸의 가장자리 끝까지 그림을 채운다.
7. 순수한 자홍색(마젠타, #FF00FF) 부분은 게임에서 투명하게 뚫리는 자리다. 넓은 자홍색 자리는 자홍색 그대로 둔다. 그림과 자홍색의 경계에서는 그림의 색을 경계까지 꽉 채우고, 자홍색 쪽으로 한두 픽셀 넘어가도 괜찮다. 그림 색과 자홍색을 섞은 분홍·보라색 테두리(부드러운 경계)는 만들지 않는다. 경계의 정확한 모양은 내가 원본으로 다시 맞추므로 신경 쓰지 않아도 된다.
8. 글자와 숫자, 화살표(표지판, 간판)는 같은 글자, 같은 위치와 크기, 같은 색으로, 윤곽이 매끈한 곡선과 직선이 되게 또렷하게만 한다. 도트나 계단 모양이 남으면 안 된다. 글자를 바꾸거나 지어내지 않는다. 좌우가 뒤집힌 글자(거울상)는 뒤집힌 그대로 둔다. 일부러 넣은 것이다. 읽을 수 없게 뭉개진 작은 글자는 지어내지 말고 뭉개진 채로 선명하게만 한다.
9. 결과는 첨부한 그림과 같은 비율, 같은 크기로 만든다. 서명, 워터마크, 원본에 없는 글자를 넣지 않는다.

'''

UI_WHAT = '''- 모든 입력은 레이싱 게임 화면에 겹쳐 보이는 계기판·아이콘 그림(HUD) 한 장을 회색 바탕 가운데에 크게 놓은 것이다. 여러 부품(속도계, 회전계, 화살표, 버튼, 로고)을 한 장에 빽빽하게 모아 둔 "부품 판"이고, 하나의 장면이 아니다.'''

UI_INSTRUCTIONS = '''첨부한 그림은 1999년 PC 3D 레이싱 게임(니드 포 스피드 4)의 화면 표시(HUD) 부품 판이다. 속도계·회전계 눈금판, 바늘 자리, 숫자, 화살표, 버튼, 막대, 로고 같은 부품을 한 장에 빽빽하게 모아 둔 것이고, 가로세로 256픽셀의 작은 원본을 확대한 것이라 흐릿하고 계단 모양이 보인다. 원작 그대로 다시 그려서, 같은 부품 판의 선명한 고해상도판을 만들어 줘.
1. 부품의 위치, 크기, 모양을 원본과 정확히 겹치게 그대로 둔다. 부품을 옮기거나, 키우거나, 줄이거나, 돌리거나, 합치거나, 새로 배치하지 않는다. 부품 사이의 빈 곳과 회색 바탕은 그대로 둔다. 게임은 이 판에서 좌표로 부품을 잘라 쓰므로 한 픽셀만 밀려도 화면이 깨진다.
2. 내용을 그대로 둔다. 부품을 더하거나 빼지 않는다. 숫자(0, 50, 100, 150 … 250, 1~9, 80, 160, 240, 320, 400 등)와 글자(NFS, kph, mph)는 같은 글자, 같은 자리, 같은 크기, 같은 색으로만 다시 쓴다. 숫자를 바꾸거나 지어내지 않는다.
3. 눈금은 같은 개수, 같은 각도, 같은 길이로 둔다. 원은 매끈한 원으로, 직선은 곧은 직선으로, 글자와 숫자와 화살표는 윤곽이 매끈한 벡터 그림처럼 또렷하게 그린다. 도트, 계단 모양 윤곽, 뭉개진 얼룩이 남으면 안 된다.
4. 색과 빛을 그대로 둔다. 각 부품의 색, 밝기, 그러데이션, 광택을 원본과 같게 한다. 더 화사하게, 더 진하게 만들지 않는다. 새로운 그림자, 테두리, 질감, 반사를 더하지 않는다.
5. 화풍은 원본 그대로 깔끔한 게임 그래픽(평평한 색과 단순한 그러데이션)이다. 사진처럼 바꾸거나, 입체감을 더하거나, 금속 질감을 넣지 않는다.
6. 순수한 자홍색(마젠타, #FF00FF) 부분은 게임에서 투명하게 뚫리는 자리다. 자홍색 자리는 자홍색 그대로 둔다. 부품과 자홍색의 경계에서는 부품의 색(검은 윤곽선 등)을 경계까지 꽉 채우고, 부품 색과 자홍색을 섞은 분홍·보라색 테두리는 만들지 않는다. 경계의 정확한 모양은 내가 원본으로 다시 맞추므로 신경 쓰지 않아도 된다.
7. 부품 판의 바깥 네 가장자리에 테두리, 그림자, 어두워짐을 넣지 않는다. 판 밖의 회색은 단색 회색 그대로 둔다.
8. 결과는 첨부한 그림과 같은 비율, 같은 크기로 만든다. 서명, 워터마크, 원본에 없는 글자를 넣지 않는다.

'''

PROMPT = '''# NFS4 리드로잉: redraw{n}

```
{folder} 폴더를 처리해라. 중간에 나에게 묻지 말고, 다 끝나거나 사용 한도에 걸려 더 못 할 때만 멈추고 보고해라. 그 밖의 이유로는 멈추지 않는다.

[대상]
- 폴더: {folder} ({count}장)
- 할 목록: todo.txt (한 줄에 이름 하나)
- 입력: send\\<이름>.png  (크기는 1024x1024)
- 출력: received\\<이름>.png  (입력과 같은 이름)
- 기록: log.md
- 이미 received\\ 에 있는 이름은 건너뛴다.
{what}

[모델과 설정]
- 이미지는 지금 쓸 수 있는 것 가운데 가장 최신이고 가장 품질이 좋은 이미지 모델로 만든다.
- 품질 설정이 있으면 가장 높게(high) 한다. 입력 그림을 얼마나 지킬지 정하는 설정(input fidelity 등)이 있으면 가장 높게(high) 한다.
- 반드시 "입력 그림을 첨부해서 고치는 방식(이미지 편집)"으로 만든다. 글로만 설명해서 새로 그리는 방식은 쓰지 않는다.
- 결과 크기는 입력과 같은 크기(정사각형)로 요청한다. 도구가 다른 크기(예: 1254x1254)로 내놓아도 정사각형이면 그대로 쓴다(받은 크기 그대로 보관한다).
- 모델 이름이나 설정을 고를 수 없으면 기본값으로 그대로 진행한다. 그것 때문에 멈추지 않는다.
- log.md 맨 위에 쓴 모델과 설정을 한 줄 적는다(이미 있으면 다시 적지 않는다). 이전 기록은 지우지 말고 그 아래에 이어 적는다.

[도구의 자동 저장]
- 이미지 도구가 그림을 자기 폴더에 자동으로 저장하는 것은 괜찮다. 막을 필요가 없고, 그 때문에 멈추지 않는다.
- 그 자동 저장 파일은 지우거나 옮기지 말고 그대로 둔다. 거기서 결과를 received\\<이름>.png 로 복사한다.

[순서]
1. todo.txt 를 위에서부터 한 줄씩 처리한다. received\\<이름>.png 가 이미 있으면 건너뛴다.
2. send\\<이름>.png 를 입력으로, 아래 [지시문]을 그대로 넣어 이미지 편집으로 다시 그린다.
3. 결과가 정사각형인지 확인한다(가로÷세로가 1% 안쪽). 다르면 한 번 더 그리고, 또 다르면 그대로 저장하고 비고에 "비율 다름"이라고 적는다.
4. received\\<이름>.png 로 저장한다. 크기는 바꾸지 않고 도구가 준 그대로 저장한다. received\\ 안에 다른 이름이나 후보 파일은 남기지 않는다.
5. log.md 에 한 줄 적는다: "이름 | 결과 크기 | 완료/실패 | 비고".
6. 한 장이 오류로 실패하면 한 번 다시 시도하고, 또 실패하면 "실패"로 적고 다음으로 넘어간다.
7. 저장하기 전에 결과를 직접 보고 [결과 검사]를 한다. 통과하지 못하면 지시문 끝에 틀린 점을 한 줄로 붙여 한 번만 더 그린다. 그래도 통과하지 못하면 그대로 저장하고 비고에 틀린 점을 적는다. 이미 저장한 장을 다시 그리지 않는다.
8. [결과 검사]에 없는 작은 차이(결의 재구성, 조금 다른 밝기, 몇 픽셀 어긋남, 자홍색 경계의 작은 차이)로는 다시 그리지 않는다. 비고에 적을 필요도 없다. 내 쪽 맞춤 단계가 원본에 맞춰 고친다.

[결과 검사]
아래 넷만 본다. 이것만 걸리면 다시 그린다.
- 칸의 수와 위치: 입력과 같은 자리에 같은 수의 네모 칸이 있어야 한다. 칸이 합쳐지거나, 크게 옮겨지거나, 커지거나, 회색 간격으로 그림이 번져 나가면 실패다.
- 같은 그림: 각 칸을 원본 크기로 줄여 봤을 때 같은 물건·같은 무늬·같은 글자여야 한다. 물건이 생기거나 빠지거나, 글자가 바뀌면 실패다.
- 선명함: 원래 크기로 봤을 때 네모난 도트, 계단 모양 윤곽(특히 글자·화살표), 뭉개진 얼룩이 보이지 않아야 한다. 원본을 거의 그대로 확대한 것(흐릿한 것)도 실패다.
- 칸 가장자리에 테두리·액자·그림자·어두워짐이 생기면 실패다.

[지시문]
{instructions}[하지 말 것]
- 이미지 모델 대신 파이썬·포토샵류 필터(샤픈, 업스케일러, 리사이즈, 색 줄이기, 흐리기)로 처리하기.
- 빨리 끝내려고 대충 처리하거나, 검사 없이 저장하기.
- send\\, todo.txt, boxes.json, 프롬프트.md 를 고치거나 지우거나 옮기기.
- 결과를 잘라내거나 크기를 맞추는 후처리(모음 나누기, 크기 맞춤, 투명 처리는 내가 따로 한다).
- {folder} 밖의 파일과 폴더를 고치거나 지우기. (이미지 도구가 자기 폴더에 자동 저장하는 것만은 예외로 허용한다.)
- received\\ 와 log.md 말고 새 파일 만들기.

[마지막 보고]
1. 이번에 완료한 수, 건너뛴 수(이미 있던 것), 실패 수
2. 실패하거나 "비율 다름"인 이름 (안전 검사 거부는 따로 표시)
3. 쓴 모델과 설정
4. [결과 검사]에 걸린 채 저장한 이름과 이유 (작은 차이는 적지 않는다)
5. 멈춘 이유 (다 끝남 / 사용 한도 / 기타)와 멈춘 이름
```
'''


def main():
    argv = sys.argv[1:]
    root = pathlib.Path('D:/upscale/NFS4')
    if '--root' in argv:
        i = argv.index('--root')
        root = pathlib.Path(argv[i + 1])
        del argv[i:i + 2]
    sky = '--sky' in argv
    args = [a for a in argv if not a.startswith('--')]
    n, tracks = int(args[0]), [t.upper() for t in args[1:]]
    index = json.loads((root / 'input' / 'index.json').read_text(encoding='utf-8'))
    out = root / ('redraw%d' % n)
    (out / 'send').mkdir(parents=True, exist_ok=True)
    (out / 'received').mkdir(exist_ok=True)

    seen = {}          # pixel hash -> first key
    for k in range(1, n):   # pictures an earlier bundle already holds are not sent again
        bp = root / ('redraw%d' % k) / 'boxes.json'
        if bp.exists():
            for key, b in json.loads(bp.read_text(encoding='utf-8')).items():
                seen[b['hash']] = None
    todo, boxes, cells, big = [], {}, [], []
    for key in sorted(index):
        e = index[key]
        if e['track'].upper() not in tracks or min(e['w'], e['h']) < 32:
            continue
        if e['file'].upper().startswith('SKY') != sky:
            continue
        img = Image.open(root / 'input' / (key + '.png')).convert('RGBA')
        h = hashlib.sha1(('%dx%d' % img.size).encode() + img.tobytes()).hexdigest()[:16]
        if h in seen:
            if seen[h]:
                boxes[seen[h]]['same'].append(key)
            continue
        seen[h] = key
        boxes[key] = {'hash': h, 'w': e['w'], 'h': e['h'], 'alpha': e['alpha'], 'same': []}
        for extra in ('soft', 'out_max'):          # UI pictures (redraw_export.py --dump)
            if extra in e:
                boxes[key][extra] = e[extra]
        (big if e.get('big') else cells).append((key, img))

    # a big picture (the HUD) alone on its sheet, as large as the gap round it allows; the rest nine to a sheet
    # each track on sheets of its own, named after it, so one bundle can hold several tracks
    groups = []
    for t in tracks:
        mine = [c for c in cells if index[c[0]]['track'].upper() == t]
        groups += [('t_sheet_%s%s_s%02d' % ('SKY_' if sky else '', t, s // 9), mine[s:s + 9], BOX, 3) for s in range(0, len(mine), 9)]
    groups += [('t_sheet_UI_%s' % key.split('/')[-1], [(key, img)], CANVAS - 2 * GAP, 1) for key, img in big]
    for name, group, box, per in groups:
        sheet = Image.new('RGB', (CANVAS, CANVAS), GREY)
        for i, (key, img) in enumerate(group):
            k = box / max(img.size)
            w, h = round(img.width * k), round(img.height * k)
            x = GAP + (i % per) * (box + GAP) + (box - w) // 2
            y = GAP + (i // per) * (box + GAP) + (box - h) // 2
            # colour enlarged smoothly; the see-through shape stays hard-edged and flat magenta
            rgb = img.convert('RGB').resize((w, h), Image.BICUBIC)
            mask = img.getchannel('A').resize((w, h), Image.NEAREST).point(lambda a: 255 if a >= 128 else 0)
            cell = Image.new('RGB', (w, h), KEY)
            cell.paste(rgb, (0, 0), mask)
            sheet.paste(cell, (x, y))
            boxes[key].update({'sheet': name, 'canvas': [CANVAS, CANVAS], 'box': [x, y, w, h]})
        sheet.save(out / 'send' / (name + '.png'))
        todo.append(name)
    (out / 'todo.txt').write_text('\n'.join(todo) + '\n', encoding='utf-8')
    (out / 'boxes.json').write_text(json.dumps(boxes, indent=1), encoding='utf-8')
    text = PROMPT.format(n=n, folder=str(out), count=len(todo),
        what=UI_WHAT if big and not cells else TRACK_WHAT, instructions=UI_INSTRUCTIONS if big and not cells else TRACK_INSTRUCTIONS)
    if root.name.upper() == 'NFS3':     # the same tools make NFS3's track bundles (D:/upscale/NFS3, read from F:/NFS3-iOS)
        text = text.replace('NFS4 리드로잉', 'NFS3 리드로잉').replace('1999년 PC 3D 레이싱 게임(니드 포 스피드 4)', '1998년 PC 3D 레이싱 게임(니드 포 스피드 3)')
    (out / '프롬프트.md').write_text(text, encoding='utf-8')
    print('%s: %d sheets, %d pictures (%d more share one)' % (out, len(todo), len(cells) + len(big), sum(len(b['same']) for b in boxes.values())))


if __name__ == '__main__':
    main()
