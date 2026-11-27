ObjC.bindFunction("mach_absolute_time", ["uint64", []]);
function run() {
    const clock = () => Number($.mach_absolute_time());
    const p = Application("System Events").processes.byName("System Settings");
    if (!p.frontmost() || p.windows[0].name() !== "Wallpaper") throw Error("Wallpaper must be frontmost");
    const w = p.windows[0], origin = w.position(), steps = [];
    try {
        for (let i = 0; i < 36; i++) {
            const n = i % 12, target = [origin[0]+20*(n<6?n+1:11-n), origin[1]];
            const begin = clock();
            w.position = target;
            const setEnd = clock();
            const actual = w.position();
            const readEnd = clock();
            if (actual[0]!==target[0] || actual[1]!==target[1]) throw Error("Position mismatch at move "+(i+1));
            steps.push({move:i+1,begin,setEnd,readEnd});
        }
    } finally {w.position = origin;}
    return JSON.stringify(steps);
}
