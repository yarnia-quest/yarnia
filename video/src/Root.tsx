// The YarniaDemo composition below is rendered to video/out/yarnia-demo.mp4 by
// .github/workflows/render-demo-video.yml (Remotion render on a CI runner).
import "./index.css";
import { Composition } from "remotion";
import { YarniaDemo } from "./yarnia/YarniaDemo";
import { totalFrames } from "./yarnia/timeline";
import { FPS } from "./yarnia/theme";

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="YarniaDemo"
        component={YarniaDemo}
        durationInFrames={totalFrames}
        fps={FPS}
        width={1080}
        height={1920}
      />
    </>
  );
};
